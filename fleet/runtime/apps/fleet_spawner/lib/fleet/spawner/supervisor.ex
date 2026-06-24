defmodule Fleet.Spawner.Supervisor do
  @moduledoc """
  DynamicSupervisor top-level pour les pods. Stratégie `:one_for_one`,
  `max_restarts: 3, max_seconds: 60`.

  Les pods sont **tous `:temporary`** (cf.
  `Fleet.Spawner.restart_strategy_for/1`) : le supervisor ne **ressuscite
  jamais** un pod. Un pod mort (sortie normale OU crash) est retiré, point.

  Comme les enfants `:temporary` ne comptent **pas** dans l'intensité de restart,
  `max_restarts` ne peut pas déclencher de **cascade fleet-wide** —
  il est de fait inerte tant que tous les enfants sont `:temporary`.
  La résurrection est un acte **délibéré** du boot-orchestrator depuis le
  desired-state (cap-profile), pas un restart OTP : c'est la seule voie de relance.
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
