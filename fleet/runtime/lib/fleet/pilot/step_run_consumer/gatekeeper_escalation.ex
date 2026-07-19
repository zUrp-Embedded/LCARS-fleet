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

  ## Boundary: explicit seams struct (not the whole `state`)

  The cluster reads ONLY the seams below from the consumer's `state` — never the whole `state`
  (hardened boundary: `@enforce_keys` forces the fields, an access `seams.<other>` does not
  compile).

  **Last revised**: 2026-07-19
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
    defstruct [:task_queue, :spawner, :repo, :forge, :forge_opts, :loader]

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
            loader: module() | nil
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
    # Judge naming (same shape as the PR judges): one pod per eval'd issue, deterministic →
    # a re-dispatch of the same eval lands on the same pod id (idempotent), and the single-brick
    # model keeps concurrent same-project gatekeepers structurally absent.
    pod_id = "issue-#{n}-#{gk_role}"

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
  # spawn opts (R18: a one-shot without brief is refused at the spawner). Already alive (previous
  # eval closing / re-dispatch) → plain wake: the pod pulls the enqueued brief when free.
  defp spawn_gatekeeper(%Seams{} = seams, pod_id, brief) do
    loader = seams.loader || Fleet.CapProfile
    gk_role = Fleet.Pilot.Roles.gatekeeper_role()

    with {:ok, base} <- loader.load(gk_role),
         {:ok, cap} <- loader.compose(gk_role, loader.default_modops(base)) do
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
          # Previous eval still closing (or re-dispatch): the brief is queued — wake, best-effort.
          _ = seams.spawner.wake_pod(pod_id)
          :ok

        {:error, _reason} = err ->
          err
      end
    end
  end
end
