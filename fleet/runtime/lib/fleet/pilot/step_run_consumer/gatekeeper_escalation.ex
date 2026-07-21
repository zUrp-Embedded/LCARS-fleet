defmodule Fleet.Pilot.StepRunConsumer.GatekeeperEscalation do
  @moduledoc """
  IMPURE "gatekeeper escalation" cluster (async-out) of `Fleet.Pilot.StepRunConsumer`.

  When a `:soft`/undecidable-terminal gate escalates (`{:dispatch_gatekeeper, _}`), this module
  summons the gatekeeper — a **ONE-SHOT per-project judge since the 2026-07-19 reorg** (cf.
  DESIGN-carte-des-roles §7; the old resident singleton `Fleet.Workflow.Gatekeeper` is gone —
  it was documented as an MVP awaiting the project model, and the project model now exists):

    1. enqueues the eval brief to the deterministic pod id `issue-<n>-gatekeeper` (judge naming —
       the broker holds the content BEFORE any wake: offer-then-wake ordering, no
       signal-before-content race);
    2. SPAWNS the one-shot gatekeeper (composed cap + repo binding + numeric repo id for its
       deterministic UUID — same mold as every judge; its BOOT KICK pulls the enqueued brief).
       Already alive (previous eval still closing) → plain wake instead (it pulls next);
    3. returns the `correlation_id` (= task.id) for the async resumption
       (`task_queue.work_item.completed` → `resume_gate`).

  A judge must be FRESH: each eval gets a new pod (no accumulated context), and the re-eval is
  forge-driven (the verdict is persisted — nothing needs the pod to survive). A failed spawn is
  `{:error, _}` — the caller fail-louds (`{:error, {:gatekeeper_dispatch, _}}`, the issue stays
  locked, LOUD): an eval that cannot get its judge must never silently pass.

  It does NOT DECIDE the route: the stateful decision core (`gate_decide`/`resume_gate`/
  `apply_verdict`) stays the SINGLE-AUTHORITY of the root module, which calls `dispatch/7` on the
  sole `{:dispatch_gatekeeper, _}` path.

  ## Distinct dispatch rail — DELIBERATE, verified, DO NOT merge (L1b, sonde convergence 2026-07-20)

  This dispatch shares a SKELETON with the poller-driven producer/judge dispatch
  (`StepDispatcher.Spawn.spawn_step`) — resolve profile → opts → spawn/reuse → pull → wake — but the
  resemblance is of FORM, not of substance. The truly-shared atoms are ALREADY factored out and used by
  BOTH rails: `CapProfile.resolve` (effective profile), `WakeRecovery.wake` (wake+recovery, wired here by
  C-01), `PodId.for_*`, `Spawn.resolve_repo_id`. What stays distinct is the OPERATIONAL CONTRACT, not
  duplicated logic — this rail is:

    * COMPLETION-triggered (a gate escalation), never the Poller's detection side;
    * LOCKLESS — it evals UNDER a brick that is ALREADY `lcars-in-flight`; it takes no lock of its own, so
      there is nothing to compensate → it FAIL-LOUDS (never unlock+kill);
    * ENQUEUE-BEFORE-SPAWN — the inverse of the producer's `lock → pod → enqueue` (the one-shot's boot kick
      pulls the brief; a wake before the content would be the spurious-wake race);
    * never CAPACITY-DEFERRED — a gate verdict IS the resolution of an in-flight brick; deferring it would
      stall the whole workflow, so it always dispatches;
    * carrying a defused I-CBC GateBrief, never a physicalized worker brief (no SLSA triplet).

  Doctrine (why the rail is structural, not a caprice): the gatekeeper is spawned as a one-shot pod like
  any judge, but it is LESS a production worker the fleet DISPATCHES onto a work-item than a part of the
  fleet's own GOVERNANCE mechanic — it resolves the gate and SEALS the merge. Merging this into the
  producer/judge dispatch would carry a flag per axis above (takes_lock? / enqueue_when / defer? /
  compensate? / brief_kind) — relocating the divergence into a conditional forest instead of two honest,
  self-documenting rails. Verified: kept separate ON PURPOSE.

  ## Boundary: explicit seams struct (not the whole `state`)

  The cluster reads ONLY the seams below from the consumer's `state` — never the whole `state`
  (hardened boundary: `@enforce_keys` forces the fields, an access `seams.<other>` does not
  compile).

  **Last revised**: 2026-07-21
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher.Spawn

  defmodule Seams do
    @moduledoc """
    Boundary contract of the escalation cluster: the async-out seams read from the
    `StepRunConsumer`'s `state`. Built by the caller BEFORE `dispatch/7` — the cluster never
    receives the whole `state`.
    """
    @enforce_keys [:task_queue, :spawner, :repo, :forge, :forge_opts]
    defstruct [:task_queue, :spawner, :repo, :forge, :forge_opts, :loader, :wake_recovery]

    @type t :: %__MODULE__{
            # Broker of eval briefs (prod default `Fleet.TaskQueue`).
            task_queue: module(),
            # Spawn + wake of the one-shot gatekeeper (prod default `Fleet.Spawner`).
            spawner: module(),
            # The project (`owner/name`) this consumer serves — the gatekeeper's binding.
            repo: String.t(),
            # Forge client + opts (numeric repo id resolution for the deterministic UUID).
            forge: module(),
            forge_opts: keyword(),
            # Cap-profile loader (load + compose with default modops). nil → `Fleet.CapProfile`.
            loader: module() | nil,
            # Wake-with-recovery of an already-alive gatekeeper (C-01). nil → `&WakeRecovery.wake/3`.
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()}) | nil
          }
  end

  @doc """
  Forge-driven summoning of the one-shot gatekeeper on gate escalation. Enqueue-then-spawn
  (the boot kick pulls the brief), returns the `correlation_id` (= task.id) for the
  `task_queue.work_item.completed` correlation. Failed enqueue / failed spawn → `{:error, _}`
  (the caller fail-louds; never a silent pass).

  `outputs`/`payload`/`n`/`role` are EMBEDDED in the metadata of the eval task (self-describing
  resumption context): the restarted StepRunConsumer (empty gate_evals RAM) rebuilds
  the eval_ctx from the metadata instead of silently dropping the verdict.
  """
  @spec dispatch(
          map(),
          String.t(),
          term(),
          map(),
          integer(),
          String.t() | nil,
          Seams.t()
        ) :: {:ok, term()} | {:error, term()}
  def dispatch(workflow_map, step, outputs, payload, n, role, %Seams{} = seams) do
    gk_role = Fleet.Pilot.Roles.gatekeeper_role()
    # Judge naming via the SINGLE AUTHORITY `PodId.for_issue` — REPO-QUALIFIED (codex audit F-02
    # 2026-07-19: the bare `issue-#{n}-…` literal collided across repos — two projects on issue 42
    # shared one pod id, so the first live pod could receive the OTHER project's mandate).
    # Deterministic → a re-dispatch of the same eval lands on the same pod id (idempotent).
    pod_id = Fleet.Pilot.PodId.for_issue(seams.repo, n, gk_role)

    gate = get_in(workflow_map, ["steps", step, "gate"])

    # TWO names exist for a map and they are NOT the same authority: `map["name"]` is the
    # DECLARED name (`metadata.name` of the YAML), while the reload path takes the LOADING
    # name (the file/route name, `payload["workflow_map"]` → `Loader.load!/1`). We engrave the
    # LOADING name — the one the reconstruction will feed back to the Loader. The declared
    # name stays the HUMAN label of the brief.
    load_name = Map.get(payload, "workflow_map") || Map.get(workflow_map, "name")
    declared_name = Map.get(workflow_map, "name")

    brief =
      Fleet.Workflow.GateBrief.build(%{
        step: step,
        workflow_map_id: declared_name,
        gate: gate,
        outputs: outputs
      })

    # SELF-DESCRIBING VERDICT: the eval task's metadata carries the RESUMPTION context
    # (`payload`/`n`/`role` on top of the step/loading-name already present). This task survives in
    # the broker (TaskQueue = another process) a crash of the StepRunConsumer alone → the verdict
    # (`work_item.completed`) brings this metadata back → the restarted StepRunConsumer (emptied
    # gate_evals RAM) rebuilds the eval_ctx instead of a silent `{:noreply}` (issue wedged forever).
    attrs = %{
      role: gk_role,
      brief: brief,
      metadata: %{
        "gate_eval" => true,
        "step" => step,
        "workflow_map" => load_name,
        "gate" => gate,
        "outputs" => outputs,
        "resume_payload" => payload,
        "resume_n" => n,
        "resume_role" => role
      }
    }

    # ORDER is the invariant: enqueue BEFORE spawn/wake — the one-shot's boot kick pulls the brief;
    # a kick before the content exists is the spurious-wake race.
    case seams.task_queue.enqueue(pod_id, attrs) do
      {:ok, %{id: corr}} ->
        case spawn_gatekeeper(seams, pod_id, brief) do
          :ok ->
            {:ok, corr}

          {:error, reason} ->
            # No judge will ever pull this brief → LOUD failure, never a silent stall. The caller
            # fail-louds ({:error, {:gatekeeper_dispatch, _}}) and the issue stays locked, visible.
            Logger.error(
              "StepRunConsumer: one-shot gatekeeper spawn FAILED (pod=#{pod_id}, #{inspect(reason)}) — " <>
                "gate eval cannot proceed (brief enqueued but judge-less); fail-loud upstream"
            )

            {:error, {:gatekeeper_spawn, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Spawns the ONE-SHOT gatekeeper for this eval — the judge mold: composed cap, repo binding,
  # numeric repo id (deterministic UUID → its stable per-project Desktop slot), the brief in the
  # spawn opts (a one-shot without brief is refused at the spawner). Already alive (previous
  # eval closing / re-dispatch) → plain wake: the pod pulls the enqueued brief when free.
  defp spawn_gatekeeper(%Seams{} = seams, pod_id, brief) do
    loader = seams.loader || Fleet.CapProfile
    gk_role = Fleet.Pilot.Roles.gatekeeper_role()

    with {:ok, cap} <- Fleet.CapProfile.resolve(loader, gk_role) do
      spawn_opts = [
        pod_id: pod_id,
        repo: seams.repo,
        repo_id: Spawn.resolve_repo_id(seams.forge, seams.repo, seams.forge_opts),
        brief: brief
      ]

      case seams.spawner.spawn_pod(cap, pod_id, spawn_opts) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          # Previous eval still closing (or re-dispatch): the brief is queued (enqueue-before-spawn) — wake
          # WITH RECOVERY. C-01 (sonde convergence 2026-07-20): a bare `wake_pod`-then-`:ok` SWALLOWED a
          # failed wake → a dead/stuck pod left the eval brief pending, the gate announced-but-never-run,
          # the issue silently locked with NO failure reported (the dispatcher, by contrast, has recovery).
          # Route through the SAME `WakeRecovery` — the module was BUILT for this ("gatekeeper reboot",
          # brief already queued): re-roll (respawn + re-wake), then sysadmin escalation at the cap. The
          # verdict is forge-driven (nothing needs THIS pod to survive), so a surfaced `{:error, _}`
          # fail-louds upstream (issue stays visible), never a silent stall. wake_fun routed through the
          # injected spawner (test seam).
          wake_recovery = seams.wake_recovery || (&Fleet.Pilot.WakeRecovery.wake/3)

          wake_recovery.(
            pod_id,
            fn -> seams.spawner.spawn_pod(cap, pod_id, spawn_opts) end,
            wake_fun: &seams.spawner.wake_pod/1,
            op: "gatekeeper-wake"
          )

        {:error, _reason} = err ->
          err
      end
    end
  end
end
