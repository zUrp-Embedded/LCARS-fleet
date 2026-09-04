defmodule Fleet.Spawner.Application do
  @moduledoc """
  Spawner domain supervisor — a plain Supervisor named `Application` like every domain's root,
  not an OTP app callback (the only one is `Fleet.Application`).

  ## Permanent pod boot: SOLE authority = BootOrchestrator

  The boot of permanent pods (`Fleet.Spawner.PermanentBoot.boot_permanent_pods/1`) is
  orchestrated **only** by `Fleet.Admiral.BootOrchestrator` (post-readiness, guarded by
  `:lcars_fleet, :admiral_start_boot_orchestrator`). This supervisor boots no permanent pod: a
  second boot path would double-boot. A single boot authority, period.

  Two distinct knobs: `:admiral_start_boot_orchestrator` (is the orchestrator running?) and
  `:spawner_boot_permanent_at_start` (does it boot the permanent pods? read through
  `PermanentBoot.auto_boot_enabled?/0`, **default true**; `LCARS_BOOT_PERMANENT_AT_START=false`
  disables it — boot_complete emitted, 0 pod spawned).
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
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
