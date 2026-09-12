defmodule Fleet.Spawner.Application do
  @moduledoc """
  Supervises the spawner's Registry, pod supervisor and optional consumers.
  This is a domain supervisor, not an OTP application callback.

  Permanent pods are started after readiness by `Fleet.Admiral.BootOrchestrator`.
  `:admiral_start_boot_orchestrator` controls that orchestrator; the separate
  `:spawner_boot_permanent_at_start` flag controls whether it boots permanent pods
  (see `PermanentBoot.auto_boot_enabled?/0`).
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
