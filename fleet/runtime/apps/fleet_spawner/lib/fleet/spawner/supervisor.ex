defmodule Fleet.Spawner.Supervisor do
  @moduledoc """
  DynamicSupervisor top-level pour les pods.

  Stratégie `:one_for_one` avec `max_restarts: 3, max_seconds: 60` :
  3 crashes en 60s sur un même pod → supervisor stop ce pod (pattern
  `:degraded` cohérent topologie-ring L235). Évite restart loop infini
  sur fail catastrophique.
  """

  use DynamicSupervisor

  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_args) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
