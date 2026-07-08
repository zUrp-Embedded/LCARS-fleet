defmodule Fleet.Pilot.Application do
  @moduledoc """
  Supervisor for the `fleet_pilot` app — **STEP mode only** (the forge IS the state machine).

  Starts, if `:step_dispatch?` is configured (`config/runtime.exs` from the env) and the forge
  `base_url` resolves, the three processes of the forge-state-machine rail:

    * `Fleet.Pilot.Poller` (step mode) — **MULTI-PROJECT**: DISCOVERS the human's repos by
      topic (`lcars-fleet-<human>`, no more hard-coded `:poll_repo`), dispatches the **assigned issues**
      (assignee=human) to the spawn of the **producer** role (`StepDispatcher`).
    * `Fleet.Pilot.StepRunConsumer` — Bus consumer: on `pod.completed`, runs the **end-of-step-run**
      (publish of the git-native deliverable → system push → PR open → merge). Without it, the chain
      does not advance past the producer spawn.
    * `Task.Supervisor` (`StepRunConsumer.task_supervisor/0`) — offload of the step_run completion: the
      `git push` ≤30s does not block the `StepRunConsumer` singleton. Started BEFORE the StepRunConsumer (which refers to it).
    * `Fleet.Pilot.IncidentConsumer` (+ its `Task.Supervisor`) — Bus consumer SEPARATE from the pod FAILURE
      events (`pod.failed`/`wake.failed`) → `IncidentRegistry`. Concern distinct from the end-of-step-run
      (isolated blast-radius: a burst of failures does not share the StepRunConsumer's mailbox).

  ## History — legacy rail REMOVED (2026-06-16)

  The old `AutoDispatcher` rail (Gitea webhook `gitea.*` → `Routing` catalogue → `Dispatcher` →
  `PipelineInvoker` → `Fleet.Workflow.start_pipeline` = RAM engine `Executor`) has been **removed**:
  the dual delivery model (RAM + forge) is eliminated, only the **forge rail** remains. With it
  disappeared `auto_dispatcher.ex` / `dispatcher.ex` / `pipeline_invoker.ex`, the legacy `do_poll` mode
  of the `Poller`, and the `guard_no_duplicate_poller!` guard (no more possible collision: a single Poller).
  The RAM engine (`fleet_workflow`) falls downstream (`start_pipeline` orphaned).
  """

  use Application

  @impl Application
  def start(_type, _args) do
    # The forge pool starts UNCONDITIONALLY, before the step rail: the ForgeClient is also called
    # by `create_issue` (fleet_mcp) outside the Poller/StepRunConsumer rail, so the pool must exist as soon as
    # fleet_pilot boots. Lazy (no connection until a request) → harmless outside prod/tests.
    children = [forge_finch_spec() | step_children()]

    # `:one_for_one` (not `:rest_for_one`) even though the children refer to each other in order
    # (Task.Supervisor + IncidentRegistry started BEFORE Poller + StepRunConsumer which use them):
    # these references are by GLOBAL NAME (resolved at EACH call — `Task.Supervisor.start_child(name, …)`,
    # `IncidentRegistry` via its process name), NEVER a pid captured at init. So if IncidentRegistry
    # or the Task.Supervisor crashes and restarts, the Poller/StepRunConsumer re-finds it under the same name on
    # the next call — no need to restart them in cascade (which `:rest_for_one` would do). Per-process
    # isolation (a crash kills only one) is the right regime here.
    #
    # EXPLICIT restart bounds (aligned with TaskQueue 3/60): >3 crashes/60s of a rail singleton =
    # crash loop → we bubble up to the root supervisor rather than hammering. Deliberate window choice.
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      name: Fleet.Pilot.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  # HTTP pool dedicated to the ForgeClient. `conn_max_idle_time: 30_000` closes any connection left idle >30s
  # BEFORE the forge closes it server-side (the Finch default `:infinity` would keep it until
  # it goes stale → next call hangs until receive_timeout, suspected cause of the ~30s
  # cumulated on create_issue). Simple HTTP/1 pool, lazy. `Req.request(finch: Fleet.Pilot.ForgeFinch)`
  # on the ForgeClient side uses it.
  defp forge_finch_spec do
    {Finch, name: Fleet.Pilot.ForgeFinch, pools: %{default: [conn_max_idle_time: 30_000]}}
  end

  @doc """
  Liveness status of the forge-state-machine step rail, for readiness. fleet_pilot
  owns the rail topology → it is the one that knows whether the singletons are alive (fleet_api only
  asks, no leak of Ring 2 process names into Ring 4).

    * `{:inactive, _}`    — `:step_dispatch?` off (rail deliberately absent, expected outside prod-step).
    * `{:operational, _}` — Poller + StepRunConsumer alive.
    * `{:degraded, _}`    — step enabled but ≥1 singleton dead → **hollow-green caught** (the daemon
      runs but the forge rail no longer advances).
  """
  @spec step_status() :: {:inactive | :operational | :degraded, map()}
  def step_status do
    if Application.get_env(:fleet_pilot, :step_dispatch?, false) do
      poller? = is_pid(Process.whereis(Fleet.Pilot.Poller))
      step_run? = is_pid(Process.whereis(Fleet.Pilot.StepRunConsumer))

      if poller? and step_run? do
        {:operational, %{poller: true, step_run_consumer: true}}
      else
        {:degraded, %{poller: poller?, step_run_consumer: step_run?}}
      end
    else
      {:inactive, %{note: "step_dispatch? off"}}
    end
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

  # MULTI-PROJECT: no more mandatory `:poll_repo` nor remote frozen at boot — the Poller DISCOVERS its
  # repos by org-membership (`list_org_repos`, WS3) and the StepRunConsumer derives the repo+remote
  # PER-STEP-RUN from the event. The essential config that remains = the forge `base_url`: without it, neither
  # discovery (`list_org_repos`) nor push (per-step-run remote) work → dead rail. This is the
  # fail-loud guard, aimed at the real thing.
  defp step_children! do
    unless forge_base_url() do
      raise "fleet_pilot: :step_dispatch? activé mais la forge base_url est absente (config :fleet_pilot, " <>
              ":forge[:base_url] / FORGE_BASE_URL) — le Poller ne peut pas DÉCOUVRIR ses projets " <>
              "(list_org_repos) ni le StepRunConsumer dériver le remote de push. Deploy cassé, fail-loud."
    end

    interval = Application.get_env(:fleet_pilot, :poll_interval_ms, 30_000)

    [
      # Task supervisor for the offload of step_run completion (the ≤30s git push of the
      # StepRunConsumer does not block the singleton). Started BEFORE the StepRunConsumer (which refers to it).
      # max_children: bounds the burst (cascade of pod.completed -> N concurrent forge pushes =
      # thundering herd). Beyond -> {:error, :max_children}, handled fail-loud by offload_async.
      {Task.Supervisor, name: Fleet.Pilot.StepRunConsumer.task_supervisor(), max_children: 16},
      # Persistent memory of system incidents (resilient owner). Consumed by WakeRecovery
      # (kick_gatekeeper / safe_wake) AND by the IncidentConsumer (`*.failed` events). Best-effort boot
      # (forge unreachable at boot → local WAL only, no crash).
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
      # Neither `:repo` to the Poller (discovery by topic), nor `:repo`/`:remote` to the StepRunConsumer (per-step-run).
      # The routing lives in the route-comment (engraved by create_issue); the Poller reads it (state-machine).
      {Fleet.Pilot.Poller, interval_ms: interval, step_dispatch?: true},
      {Fleet.Pilot.StepRunConsumer,
       forge_opts: [], step_run_runner: &Fleet.Pilot.StepRunConsumer.offload_async/1}
    ]
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
