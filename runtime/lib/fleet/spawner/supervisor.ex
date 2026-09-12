defmodule Fleet.Spawner.Supervisor do
  @moduledoc """
  Dynamic supervisor for pod processes, bounded by `Fleet.Spawner.max_pods/0`.

  `Fleet.Spawner` supplies temporary children; this supervisor does not restart
  them after exit.
  """

  use DynamicSupervisor

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_args) do
    max = Fleet.Spawner.max_pods()

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      max_children: max
    )
  end
end
