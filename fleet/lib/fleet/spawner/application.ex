defmodule Fleet.Spawner.Application do
  @moduledoc """
  Spawner domain supervisor ("Application" is a historical name, kept to avoid
  reference churn — this is a plain Supervisor, not an OTP app callback).

  ## Permanent pod boot: SOLE authority = BootOrchestrator

  The boot of permanent pods (`Fleet.Spawner.PermanentBoot.boot_permanent_pods/0`)
  is orchestrated **only** by `Fleet.Starfleet.BootOrchestrator` (post-readiness,
  guarded by `:lcars_fleet, :starfleet_start_boot_orchestrator`). This app does **NOT**
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
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # Stamp the fleet epoch before any pod starts.
    :ok = Fleet.Spawner.BootEpoch.init()

    # Prove every canon role spawn-ready before readiness.
    if Application.get_env(:lcars_fleet, :spawner_prove_canon_at_boot, true) do
      :ok = Fleet.Spawner.CanonProof.prove_all!()
    end

    base = [
      {Registry, keys: :unique, name: Fleet.Spawner.Registry},
      Fleet.Spawner.Supervisor
    ]

    publish =
      if Application.get_env(:lcars_fleet, :spawner_start_publish_consumer, true) do
        [Fleet.Spawner.PublishConsumer]
      else
        []
      end

    reaper =
      if Application.get_env(:lcars_fleet, :spawner_start_pod_warden, true) do
        [Fleet.Spawner.PodWarden]
      else
        []
      end

    permanent_warden =
      if Application.get_env(:lcars_fleet, :spawner_start_permanent_warden, true) do
        [Fleet.Spawner.PermanentWarden]
      else
        []
      end

    children = base ++ publish ++ reaper ++ permanent_warden

    # Registry loss restarts its consumers and resets orphan-reaping grace.
    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end

  @doc """
  Reports whether the unique admin-spawn consumer is alive and subscribed.
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
