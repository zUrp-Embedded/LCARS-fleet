defmodule Fleet.Pilot.Application do
  require Logger

  @moduledoc """
  Domain supervisor (the module keeps the historical `Application` name — zero reference churn).

  Supervisor for the pilot domain — **STEP mode only** (the forge IS the state machine).

  Starts, if `:step_dispatch?` is configured (`config/runtime.exs` from the env) and the forge
  `base_url` resolves, the processes of the forge-state-machine rail:

    * `Fleet.Pilot.Poller` (step mode) — **MULTI-PROJECT**: DISCOVERS the fleet-org repos by
      org-membership (`list_org_repos`, WS3 — no hard-coded `:poll_repo`), dispatches the
      **assigned issues** (assignee=human) to the spawn of the **producer** role (`StepDispatcher`).
    * `Fleet.Pilot.StepRunConsumer` — Bus consumer: on `pod.completed`, runs the **end-of-step-run**
      (publish of the git-native deliverable → system push → PR open → merge). Without it, the chain
      does not advance past the producer spawn.
    * `Task.Supervisor` (`StepRunConsumer.task_supervisor/0`) — offload of the step_run completion: the
      `git push` ≤30s does not block the `StepRunConsumer` singleton. Started BEFORE the StepRunConsumer (which refers to it).
    * `Fleet.Pilot.IncidentConsumer` (+ its `Task.Supervisor`) — Bus consumer SEPARATE from the pod FAILURE
      events (`pod.failed`/`wake.failed`) → `IncidentRegistry`. Concern distinct from the end-of-step-run
      (isolated blast-radius: a burst of failures does not share the StepRunConsumer's mailbox).
    * `Fleet.Pilot.PollerTelemetry` — the attachment of `[:fleet_pilot, :poller, :poll]`. First child
      of the rail because it measures the rail: the poller emitted those three sites since it was
      written and nothing ever attached, so every duration was computed and dropped (BL-6-40 Ph. 0).
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # CI-11: MCP brief writes require the ops serializer outside step mode too.
    children = [forge_finch_spec()] ++ ops_object_sync_child() ++ step_children()

    # Children resolve collaborators by name, so one-for-one recovery is sufficient.
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    ]

    Supervisor.init(children, opts)
  end

  # Work/ops write serializer (CI-11) — always-on in prod, OFF in test (hermeticity, cf. init).
  defp ops_object_sync_child do
    if Application.get_env(:fleet_pilot, :start_ops_object_sync, true),
      do: [Fleet.Workflow.OpsObjectSync],
      else: []
  end

  # HTTP pool dedicated to the ForgeClient. `conn_max_idle_time: 30_000` closes any connection left idle >30s
  # BEFORE the forge closes it server-side (the Finch default `:infinity` would keep it until
  # it goes stale → next call hangs until receive_timeout, suspected cause of the ~30s
  # cumulated on create_issue). Simple HTTP/1 pool, lazy. `Req.request(finch: Fleet.Forge.finch_name())`
  # on the ForgeClient side uses it.
  @doc """
  The ForgeClient's Finch pool child spec — SINGLE writer of the pool shape, shared with
  out-of-app tooling (`mix lcars.project_template.sync` starts it standalone under its own
  supervisor: no `app.start`, a second fleet must never boot from a mix task).
  """
  def forge_finch_spec do
    {Finch, name: Fleet.Forge.finch_name(), pools: %{default: [conn_max_idle_time: 30_000]}}
  end

  @doc """
  Liveness status of the forge-state-machine step rail, for readiness. fleet_pilot
  owns the rail topology → it is the one that knows whether the singletons are alive (fleet_api only
  asks, no MCP process name leaks into the surface).

    * `{:inactive, _}`    — `:step_dispatch?` off (rail deliberately absent, expected outside prod-step).
    * `{:operational, _}` — Poller + StepRunConsumer alive.
    * `{:degraded, _}`    — step enabled but ≥1 singleton dead → **hollow-green caught** (the daemon
      runs but the forge rail no longer advances).
  """
  @spec step_status() :: {:inactive | :operational | :degraded, map()}
  def step_status do
    if Application.get_env(:fleet_pilot, :step_dispatch?, false) do
      detail =
        Map.new(step_rail_processes(), fn {key, name} ->
          {key, is_pid(Process.whereis(name))}
        end)

      # The rail is operational ONLY if EVERY essential process is up. Probing two names (Poller +
      # StepRunConsumer) while IncidentRegistry / the two Task.Supervisors / IncidentConsumer /
      # WorktreeSync / ArchFeed were dead read hollow-green: the rail NAMED in readiness was not the rail
      # MEASURED. `step_rail_processes/0` IS that rail (locked to `step_children!` by a drift test).
      # The HEALTH of the polls, beside the list of the living (BL-6-40). A rail whose processes are
      # all up but whose polls take 40 s is "operational" and is not fine — readiness stated the
      # first and kept quiet about the second.
      #
      # ⚠ The key is called `repo_poll` and NOT `tick`, because the telemetry measures ONE REPO, not
      # a cycle. `[:fleet_pilot, :poller, :poll]` is emitted once PER REPO (every emission carries
      # `repo:`), so a distribution over this key describes what one repo costs, never what a full
      # pass costs. Measured 2026-08-03: 12 repos, 30 s interval, and the counter advanced by 12 per
      # cycle. The key was first called `tick` — a name asserting a scope the mechanism does not
      # have, and on which a measurement was read wrong before the name was fixed. The cost of a
      # CYCLE is not measured here, and no name may suggest otherwise.
      #
      # ⚠ And this is where the telemetry becomes READABLE. `PollerTelemetry.stats/0` existed with
      # no production caller: `RELEASE_DISTRIBUTION=none` is the default (a deliberate choice of
      # `bin/fleet_v2`: no epmd, no multi-human collision), so NO `rpc` reaches the node. An
      # instrument nobody can query measures for nobody — the very hollow 6-06 documents, rebuilt by
      # the instrument meant to fight it.
      # Two scales, two keys, never an average of the two: `repo_poll` says what ONE REPO costs,
      # `poll_cycle` what ONE PASS costs (discovery + pod snapshot + serial fold of the R repos +
      # the two fleet-global passes). `poll_cycle` is the one to read when asking whether a value
      # frozen at the start of a pass can go stale before it ends; `repo_poll` cannot answer that,
      # it does not know how many repos exist.
      detail =
        detail
        |> Map.put(:repo_poll, repo_poll_health())
        |> Map.put(:poll_cycle, poll_cycle_health())

      if Enum.all?(detail, fn {key, up?} -> key in [:repo_poll, :poll_cycle] or up? end),
        do: {:operational, detail},
        else: {:degraded, detail}
    else
      {:inactive, %{note: "step_dispatch? off"}}
    end
  end

  # Health summary of the PER-REPO polls, or `:no_data` before the first one. TOTAL by obligation:
  # readiness is what an operator consults when things go wrong, so it must never fall because of
  # its own instrument. A dead telemeter yields `:unavailable` and the rail stays readable.
  defp repo_poll_health do
    Fleet.Pilot.PollerTelemetry.stats()
  catch
    :exit, _ -> :unavailable
  end

  # Health summary of the whole PASS. Same totality as above, and for the same reason.
  defp poll_cycle_health do
    Fleet.Pilot.PollerTelemetry.cycle_stats()
  catch
    :exit, _ -> :unavailable
  end

  @doc false
  # The registered names of the STEP rail's essential processes — the readiness DEFINITION owned HERE,
  # beside their single start site `step_children!`. EVERY process `step_children!` starts must appear
  # here (a rail with any of them dead is degraded, not a hollow "operational"); the drift test
  # `step_rail_processes ⇔ step_children!` fails if a new child is added there but not here.
  def step_rail_processes do
    [
      # The instrument is part of the rail's readiness, not an accessory: a rail running with its
      # telemetry dead is a rail nobody can measure, which is the exact state BL-6-40 named. Better
      # `:degraded` and visible than `:operational` and blind.
      poller_telemetry: Fleet.Pilot.PollerTelemetry,
      poller: Fleet.Pilot.Poller,
      step_run_consumer: Fleet.Pilot.StepRunConsumer,
      step_run_task_supervisor: Fleet.Pilot.StepRunConsumer.task_supervisor(),
      incident_registry: Fleet.Pilot.IncidentRegistry,
      incident_consumer: Fleet.Pilot.IncidentConsumer,
      incident_task_supervisor: Fleet.Pilot.IncidentConsumer.task_supervisor(),
      worktree_sync: Fleet.Pilot.WorktreeSync,
      arch_feed: Fleet.Pilot.ArchFeed,
      fleet_feed: Fleet.Pilot.FleetFeed
    ]
  end

  # Processes of the STEP rail (the forge IS the state machine). Started iff `:step_dispatch?` is
  # true. `[]` if `:step_dispatch?` absent/false (deliberately inert app — test hermeticity).
  #
  # If `:step_dispatch?` is TRUE but the essential config does not resolve, we do NOT silently fall back
  # to `[]` (that would start the app "green" without Poller/StepRunConsumer → forge rail dead, zero
  # crash, zero log). The operator ASKED for step mode → incomplete config = broken deploy →
  # fail-loud at boot.
  defp step_children do
    if Application.get_env(:fleet_pilot, :step_dispatch?, false) do
      step_children!()
    else
      []
    end
  end

  @doc false
  # Test seam: exposes the rail child-specs WITHOUT starting the supervisor (which would register the
  # singletons under their global names → conflicts / parasitic boot). Used to verify the fail-loud guard.
  def step_children_for_test, do: step_children()

  # MULTI-PROJECT: no mandatory `:poll_repo` nor remote frozen at boot — the Poller DISCOVERS its
  # repos by org-membership (`list_org_repos`, WS3) and the StepRunConsumer derives the repo+remote
  # PER-STEP-RUN from the event. The essential config that remains = the forge `base_url`: without it, neither
  # discovery (`list_org_repos`) nor push (per-step-run remote) work → dead rail. This is the
  # fail-loud guard, aimed at the real thing.
  defp step_children! do
    unless forge_base_url() do
      raise "fleet_pilot: :step_dispatch? enabled but the forge base_url is absent (config :fleet_pilot, " <>
              ":forge[:base_url] / FORGE_BASE_URL) — the Poller cannot DISCOVER its projects " <>
              "(list_org_repos) nor can the StepRunConsumer derive the push remote. Deploy broken, fail-loud."
    end

    # Publish the workflow catalogue IMAGE first: the two guards below — and every
    # runtime consumer after them — then read what was just proved, never the live
    # disk (a post-boot catalogue edit is inert until restart). Missing, empty or
    # invalid catalogue → raise HERE, same dead-man's-switch as the base_url guard.
    Fleet.Workflow.Loader.publish_image!()

    validate_card_juries!()
    validate_card_steps!()
    validate_structural_roles!()
    validate_doc_card!()

    # The verdict wire schema (gate-decision-v1) is EXECUTED on every ingest by
    # Verdict.gate_decision/1 — resolved here once, fail-loud: a broken deploy artifact
    # refuses at rail boot instead of crashing the StepRunConsumer singleton on the
    # first verdict.
    Fleet.Pilot.StepRunConsumer.Verdict.load_schema!()

    interval = Application.get_env(:fleet_pilot, :poll_interval_ms, 30_000)

    [
      # The poller's telemetry, ATTACHED (BL-6-40 Phase 0). Started BEFORE the Poller so no tick is
      # emitted into the void, and it is the FIRST child of the rail because it measures the rail:
      # the three emission sites have existed since the poller was written and nothing ever called
      # `:telemetry.attach`, so every duration was computed and dropped. Nothing else in BL-6-40 is
      # provable until this exists.
      Fleet.Pilot.PollerTelemetry,
      # Task supervisor for the offload of step_run completion (the ≤30s git push of the
      # StepRunConsumer does not block the singleton). Started BEFORE the StepRunConsumer (which refers to it).
      # max_children: bounds the burst (cascade of pod.completed -> N concurrent forge pushes =
      # thundering herd). Beyond -> {:error, :max_children}, handled fail-loud by offload_async.
      {Task.Supervisor, name: Fleet.Pilot.StepRunConsumer.task_supervisor(), max_children: 16},
      # Persistent memory of system incidents (resilient owner). Consumed by WakeRecovery
      # (kick_gatekeeper / safe_wake) AND by the IncidentConsumer (`*.failed` events). The truth lives
      # in the local WAL (written first, crash-survivable); the forge is the ASYNC cross-machine
      # backing-store. Forge unreachable at boot → WAL only, no crash: the sync re-schedules itself
      # (`:sync_forge` retry, error logged at threshold) and catches up when the forge returns.
      Fleet.Pilot.IncidentRegistry,
      # Bus consumer SEPARATE from the pod FAILURE events (`pod.failed`/`wake.failed`) → IncidentRegistry.
      # Its Task.Supervisor (offload of the registry's forge writes) started BEFORE it (it refers to it). Separate from
      # the StepRunConsumer: distinct concern, the failure burst does not share the completion's mailbox.
      {Task.Supervisor, name: Fleet.Pilot.IncidentConsumer.task_supervisor(), max_children: 16},
      {Fleet.Pilot.IncidentConsumer, runner: &Fleet.Pilot.IncidentConsumer.offload_async/1},
      # Serializer that aligns the local clone after merge: projects the deliverable (`origin/main`) onto
      # `/home/projects/<name>`. Started BEFORE Poller + StepRunConsumer — its two merge triggers
      # (`promote_pr` / `StepRunCompleter.promote`) — so it serializes their potentially concurrent
      # alignments (one `git` at a time per worktree, against index corruption).
      Fleet.Pilot.WorktreeSync,
      # The architects' per-project activity feed (Bus consumer → fleet.feed in each arch pod_dir +
      # the single informational wake on the :delivered unlock). Rides the step rail: its lines ARE
      # step milestones — same lifecycle, hermetic in tests for free (step off).
      Fleet.Pilot.ArchFeed,
      # The front desk's INCIDENT feed (Bus consumer -> the permanent starfleet pod). Twin gesture,
      # opposite scope: it carries only what the registry already ESCALATED, so the fleet-blindness
      # of starfleet is untouched — it learns that something BROKE, never who is working.
      Fleet.Pilot.FleetFeed,
      # Neither `:repo` to the Poller (org-membership discovery), nor `:repo`/`:remote` to the StepRunConsumer (per-step-run).
      # The routing lives in scoped labels `wfmap/*`+`stage/*` (engraved by `post_route`); the Poller reads them (state-machine).
      # subscribe_gitea: the webhook accelerates the tick (a hint; the poll remains the truth).
      {Fleet.Pilot.Poller, interval_ms: interval, subscribe_gitea: true},
      {Fleet.Pilot.StepRunConsumer,
       forge_opts: [], step_run_runner: &Fleet.Pilot.StepRunConsumer.offload_async/2}
    ]
  end

  # F-C061 (jury own-goal, re-seated on the CARDS) — the jury lives in each workflow map
  # (`spec.jury`, schema-required; the card governs the judgment layer, no engine config).
  # The schema guards the SHAPE but not absurd CONTENT: a non-role login in a card's jury
  # would be LAID on PRs (`request_reviews_step`) and bumped into `required_approvals`, then
  # WEDGE at dispatch (no cap-profile → silent `:no_role`). We validate at boot that EVERY
  # jury role of EVERY canon card resolves to a `brief_kind: judge` cap-profile — a jury
  # that can't judge = a broken canon, fail-loud HERE, not a silent wedge on the first PR.
  # (Symmetric to the read-frontier filter in `StepDispatcher.dispatch_review`, which
  # restricts the forge-sourced reviewer set to the card's jury: this guards the canon
  # side, that guards the forge side.)
  # The enumeration is the BANG form: a missing root or an empty catalogue would make
  # both card guards vacuously true (readiness green with zero loadable card, first
  # route raises far from the deploy fault) — refused HERE at rail boot, same
  # dead-man's-switch contract as the base_url guard above.
  # The two STRUCTURAL roles of the single-brick model — the one that codes the brick, the one that
  # signs the merge — resolved from the catalogue by capability at rail boot. Same dead-man's-switch
  # as the two card guards above: a catalogue naming neither would otherwise reach readiness GREEN
  # and die at the first dispatch, far from the deploy fault. `Fleet.Pilot.Roles` carries the
  # resolution and the refusal messages; here we only make it happen before readiness.
  # (No log line: this module has none, and the resolution is not a milestone — its FAILURE is, and
  # the raise carries it. `Fleet.Pilot.Roles` remains the place to ask who they are.)
  @doc """
  The catalogue's card + structural-role checks, off the supervision path — for the standalone
  verifier. Runs EXACTLY what `start_link/1` runs at rail boot, in the same order and through the
  same functions: publish the workflow image, then the jury/step/structural guards. It lives HERE
  and not in the verifier because these read `Fleet.Workflow` (a dep of Pilot, not of the OTP root)
  — the boundary is what keeps the workflow catalogue on this side.

  Raises on the first broken card or unresolvable structural role, same as boot; the verifier wraps
  the raise into a finding.
  """
  @spec verify_cards_and_roles!(keyword()) :: :ok
  def verify_cards_and_roles!(opts \\ []) do
    Fleet.Workflow.Loader.publish_image!()
    validate_card_juries!()
    validate_card_steps!(opts)
    validate_structural_roles!()
    :ok
  end

  defp validate_structural_roles! do
    _ = Fleet.Pilot.Roles.resolve_structural_roles!()
    :ok
  end

  defp validate_card_juries! do
    for map_name <- Fleet.Workflow.Loader.canon_names!(),
        role <- Fleet.Workflow.Loader.load!(map_name)["jury"] do
      case Fleet.CapProfile.load(role) do
        {:ok, cp} ->
          kind = Fleet.CapProfile.brief_kind(cp)

          unless kind == "judge" do
            raise "fleet_pilot: workflow map #{map_name} jury contains #{inspect(role)} whose cap-profile " <>
                    "is NOT a judge (brief_kind=#{inspect(kind)}) — the jury must be judge roles. Fix the card."
          end

        {:error, reason} ->
          raise "fleet_pilot: workflow map #{map_name} jury contains #{inspect(role)} that does NOT resolve " <>
                  "to a cap-profile (#{inspect(reason)}) — a non-role login in a jury WEDGES at dispatch " <>
                  "(no cap-profile → :no_role). Fix the card."
      end
    end

    :ok
  end

  @doc false
  # The OPS knob → CARD coherence, checked at boot (interim brake, IPC consultant 2026-08-02).
  # `Roles.doc_workflow_map/1` names the card a `genre/doc` ticket burns, and NOTHING verified
  # that the name resolves to a card that can actually SERVE a doc ticket: a dead name, or a card
  # whose steps all sit on the code face, fails at the FIRST doc ticket — silently, one wedged
  # ticket at a time, far from the config that caused it.
  #
  # THREE cases, because "absent" means two different things and only one of them is a defect:
  #   * knob EXPLICITLY set (opts or app env) → the card MUST load and carry an ops producer.
  #     Someone chose this name; a dead choice is held to account, fail-loud.
  #   * knob at its DEFAULT and the card is absent from the catalogue → a catalogue with NO doc
  #     rail, which is a legitimate deployment (an operator's own catalogue, a narrow fixture).
  #     Refusing the boot there would be a POLICY this check has no mandate to set: it says so
  #     LOUD instead, naming what such a deployment cannot do.
  #   * card PRESENT but carrying no `face: doc` producer → fail-loud whatever the knob's origin:
  #     that is the drift itself (a card that lost its doc face, the shipped canon breaking).
  #
  # What it proves is deliberately MINIMAL — it does not judge the card's shape. The per-face
  # redesign (ONE card declaring face-tagged producers, killing this knob) is the real exit; a
  # check that anticipated it would be rewritten with it. This one only closes the silence.
  # (`opts` carries the test roots; prod calls it argument-less.)
  def validate_doc_card!(opts \\ []) do
    name = Fleet.Pilot.Roles.doc_workflow_map(opts)

    chosen? =
      Keyword.has_key?(opts, :doc_workflow_map) or
        not is_nil(Application.get_env(:fleet_pilot, :doc_workflow_map))

    case Fleet.Pilot.WorkflowMapNav.safe_load(&Fleet.Workflow.Loader.load!(&1, opts), name) do
      {:ok, card} ->
        doc_producers =
          for {_step, %{"face" => "doc"} = spec} <- card["steps"] || %{},
              is_binary(Map.get(spec, "role")),
              do: spec["role"]

        if doc_producers == [] do
          raise "fleet_pilot: the doc card #{inspect(name)} (:doc_workflow_map) carries NO " <>
                  "producer step on `face: doc` — a documentary ticket routed here would be built " <>
                  "on the code face (or not at all). Declare the face on its producer step, or " <>
                  "point the knob at a card that does."
        end

        :ok

      {:error, {:workflow_map_load_failed, _name, why}} when chosen? ->
        raise "fleet_pilot: the doc card #{inspect(name)} (:doc_workflow_map) does NOT load " <>
                "(#{why}) — every `genre/doc` ticket burns this name and would wedge at its " <>
                "first dispatch. Fix the config or the card."

      {:error, {:workflow_map_load_failed, _name, why}} ->
        Logger.warning(
          "fleet_pilot: no doc card in this catalogue (default #{inspect(name)} absent: #{why}) " <>
            "— this deployment serves NO `genre/doc` ticket; such a ticket would wedge at dispatch. " <>
            "Ship a doc card or point :doc_workflow_map at one."
        )

        :ok
    end
  end

  @doc false
  # Symmetric to validate_card_juries!, for the STEP roles. The schema guards the SHAPE of
  # spec.steps.*.role (any string) but not the CONTENT: a typo or a retired role passes the boot
  # and only WEDGES at the first dispatch (`StepDispatcher` → `CapProfile.resolve` → :not_found, a
  # stuck ticket that never spawns). We resolve every canon step role at boot — a role that cannot
  # load = a broken canon, fail-loud HERE. A step without a role (nil) is skipped: it is not a
  # dispatch role. (`opts` carries `:workflow_maps_root` for tests; prod calls it argument-less.)
  def validate_card_steps!(opts \\ []) do
    for map_name <- Fleet.Workflow.Loader.canon_names!(opts),
        card = Fleet.Workflow.Loader.load!(map_name, opts),
        {step_name, spec} <- card["steps"] || %{},
        role = Map.get(spec, "role"),
        is_binary(role) do
      case Fleet.CapProfile.load(role) do
        {:ok, cp} ->
          refute_self_judgement!(map_name, step_name, role, cp, card["jury"])

        {:error, reason} ->
          raise "fleet_pilot: workflow map #{map_name} step #{inspect(step_name)} has role " <>
                  "#{inspect(role)} that does NOT resolve to a cap-profile (#{inspect(reason)}) — a bad " <>
                  "canon role WEDGES at dispatch (CapProfile.resolve → :not_found, stuck ticket). Fix the card."
      end
    end

    :ok
  end

  # A PRODUCER MAY NOT SIT ON THE JURY THAT JUDGES ITS OWN DELIVERY. The card names both halves and
  # nothing compared them: `jury` is the set of roles whose approvals gate the seal, `steps[].role`
  # is who produces — and a role in both reviews the PR it opened. The pipeline would report a
  # normal approval, because every mechanism involved worked exactly as written.
  #
  # `brief_kind` IS THE DISCRIMINANT, not the step's position. A judge role appearing as a step is
  # legitimate and shipped: `gk-smoke` runs a `reviewer` step with a soft gate, and `reviewer` is
  # also in its jury — two different acts on two different objects. Only a `worker` opens the
  # deliverable PR the jury then judges, so only a worker can collide with itself here.
  #
  # AT BOOT, over the whole canon, because a card is DATA an operator can bring: catching this at
  # dispatch would mean catching it per ticket, on the ticket, after the spawn.
  defp refute_self_judgement!(map_name, step_name, role, cp, jury) do
    if Fleet.CapProfile.brief_kind(cp) == "worker" and is_list(jury) and role in jury do
      raise "fleet_pilot: workflow map #{map_name} step #{inspect(step_name)} PRODUCES as " <>
              "#{inspect(role)}, and #{inspect(role)} is also in that card's jury " <>
              "#{inspect(jury)} — the producer would review its own PR and its approval would " <>
              "count toward the seal. Nothing downstream can tell that apart from a real review. " <>
              "Remove the role from the jury, or give the step a different producer."
    end

    :ok
  end

  # Resolved forge base_url (app config `:forge`). `nil` if absent/empty. Source of the fail-loud guard
  # above (the multi-project step rail needs it to discover AND to derive the per-step-run remotes).
  defp forge_base_url do
    case Keyword.get(Application.get_env(:fleet_pilot, :forge, []), :base_url) do
      base when is_binary(base) and base != "" -> base
      _ -> nil
    end
  end
end
