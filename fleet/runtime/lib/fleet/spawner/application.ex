defmodule Fleet.Spawner.Application do
  @moduledoc """
  Spawner domain supervisor ("Application" is a historical name, kept to avoid
  reference churn — this is a plain Supervisor, not an OTP app callback).

  ## Permanent pod boot: SOLE authority = BootOrchestrator

  The boot of permanent pods (`Fleet.Spawner.PermanentBoot.boot_permanent_pods/0`)
  is orchestrated **only** by `Fleet.Starfleet.BootOrchestrator` (post-readiness,
  guarded by `:fleet_starfleet, :start_boot_orchestrator`). This app does **NOT**
  boot the permanent pods: a second boot path here (an auto-invoke hook guarded
  by `:boot_permanent_at_start`) would double-boot — if `:boot_permanent_at_start`
  were enabled in prod (the documented path), it would boot the permanent pods IN
  ADDITION to BootOrchestrator. A single boot authority, period.

  The prod control surface: `BootOrchestrator`
  **gates** the boot of permanent pods on `:boot_permanent_at_start` (via
  `PermanentBoot.auto_boot_enabled?/0`, **default true**);
  `LCARS_BOOT_PERMANENT_AT_START=false` disables it (boot_complete emitted, 0 pod spawned).
  Two distinct knobs: `:start_boot_orchestrator` (is the orchestrator running?)
  + `:boot_permanent_at_start` (does it boot the permanent pods?). This app, for its
  part, never boots a permanent pod (no boot hook here).

  **Last revised**: 2026-07-18
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    base = [
      {Registry, keys: :unique, name: Fleet.Spawner.Registry},
      Fleet.Spawner.Supervisor
    ]

    # PublishConsumer subscribes to the Bus topic
    # admin.spawn.request → dispatches to Fleet.Spawner.spawn_pod. Gated
    # `:start_publish_consumer` (default true prod, false test).
    publish =
      if Application.get_env(:fleet_spawner, :start_publish_consumer, true) do
        [Fleet.Spawner.PublishConsumer]
      else
        []
      end

    # Periodic reaper of orphan pods (crash of the pod gen_statem process → bwrap/tmux survives). Gated
    # `:start_pod_warden` (default true prod, false test — no real pods to reap in test).
    reaper =
      if Application.get_env(:fleet_spawner, :start_pod_warden, true) do
        [Fleet.Spawner.PodWarden]
      else
        []
      end

    # Respawn of dead PERMANENT pods (cattle, not pets): TWO rails into one respawn path — a
    # `pod.failed` consumer scoped to `permanent-*`, AND a reconciliation tick (expected permanents
    # vs live Registry) that catches the deaths emitting NO event. Bounded backoff shared by both.
    # Gated `:start_permanent_warden` (default true prod, false test — no real permanents to
    # resurrect in test; the tests instantiate it with explicit seams).
    permanent_warden =
      if Application.get_env(:fleet_spawner, :start_permanent_warden, true) do
        [Fleet.Spawner.PermanentWarden]
      else
        []
      end

    # The architect's local activity feed (Bus consumer → fleet.feed in the arch pod_dir +
    # the single informational wake on the :delivered unlock). Gated `:start_arch_feed`
    # (default true prod, false test — hermeticity: no Bus consumers in async tests).
    arch_feed =
      if Application.get_env(:fleet_spawner, :start_arch_feed, true) do
        [Fleet.Spawner.ArchFeed]
      else
        []
      end

    children = base ++ publish ++ reaper ++ permanent_warden ++ arch_feed

    # No boot of permanent pods here — sole authority =
    # Fleet.Starfleet.BootOrchestrator (post-readiness). This app only
    # starts its Registry + Supervisor + PublishConsumer.
    #
    # `rest_for_one` — a restart of the Registry (1st child) ALSO restarts everything
    # that depends on it (including PodWarden). Under `one_for_one`, a Registry resurrected EMPTY while
    # the :temporary pods survive (never re-registered) made ALL the sockets look orphaned
    # → the PodWarden reaped the LIVE pods at +2 ticks. Restarting the warden re-arms its 2-tick
    # grace (suspects state reset to zero); the pods themselves are not children of this app (their
    # attachment to the Registry is lost — the reap will claim them as REAL orphans). Recovery after
    # such a reap: the PermanentWarden's RECONCILIATION tick re-derives the expected permanents
    # against the live Registry and respawns the missing ones (the event rail alone was blind here —
    # a cleanly torn-down pod emits no `pod.failed`, and BootOrchestrator is one-shot at node boot).
    # WakeRecovery remains the net for the non-permanent pods (re-spawn on the next wake/kick of a
    # pod found dead).
    Supervisor.init(children,
      strategy: :rest_for_one,
      # 3/60 explicit (common doctrine).
      max_restarts: 3,
      max_seconds: 60
    )
  end

  @doc """
  LIVE state of the admin-spawn dispatch rail, for readiness (anti-hollow-green). fleet_spawner
  owns the write-path topology → it knows whether the UNIQUE subscriber of `admin.spawn.request`
  (`Fleet.Spawner.PublishConsumer`) is alive AND subscribed. fleet_api only asks (no spawner
  process name leaks into the surface).

    * `{:operational, _}` — PublishConsumer alive AND subscribed to `fleet.events` → the
      broadcast→consume→spawn_pod chain is wired.
    * `{:degraded, _}`    — `start_publish_consumer` off, OR the process is dead, OR alive but NOT
      subscribed → `POST /api/admin/spawn` still answers 202 into the void (Bus lossy) = 202 lies, 0 pod.
  """
  @spec spawn_dispatch_status() :: {:operational | :degraded, map()}
  def spawn_dispatch_status do
    pid = Process.whereis(Fleet.Spawner.PublishConsumer)

    cond do
      not is_pid(pid) ->
        {:degraded,
         %{
           consumer: false,
           note:
             "PublishConsumer not alive (start_publish_consumer off/crashed) — POST /api/admin/spawn answers 202 into the void (0 pod)"
         }}

      not Fleet.EventRouter.Bus.subscribed?(pid) ->
        {:degraded,
         %{
           consumer: true,
           subscribed: false,
           note:
             "PublishConsumer alive but NOT subscribed to fleet.events — 202 into the void (0 pod)"
         }}

      true ->
        {:operational, %{consumer: true, subscribed: true}}
    end
  end
end
