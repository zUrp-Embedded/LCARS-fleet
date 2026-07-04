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
    # max_children (E4) : CAP GLOBAL de pods vivants — un flood de spawn (admin/spawn no-auth
    # loopback, ou un rail devenu fou) ne peut pas lancer N sessions claude (chacune = un vrai
    # process OS + tokens). Au-dela -> {:error, :max_children} rendu par spawn_pod (fail-loud chez
    # l'appelant). Config `:fleet_spawner, :max_pods` (defaut 24 : marge large au-dessus du reel —
    # ~6 permanents + workers step ; la borne vise l'ANOMALIE, pas le nominal).
    max = Application.get_env(:fleet_spawner, :max_pods, 24)

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      max_children: max
    )
  end
end
