defmodule Fleet.ProjectBootstrap.Application do
  @moduledoc """
  Application supervisor `fleet_project_bootstrap` (Ring 1, core du pod).

  `Fleet.ProjectBootstrap.Phase.Clone` est une **fonction pure** (File / Path / git) —
  aucun process : pas d'état mutable persistant, pas de concurrence interne, pas de
  fault isolation propre.

  Invoqué synchroniquement par `Fleet.Spawner.Pod` en phase PROJECT.

  Supervisor `:one_for_one` children `[]` — existe pour cohérence umbrella OTP
  (pattern `Fleet.Coord.Application`). Aucun GenServer démarré.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([],
      strategy: :one_for_one,
      name: Fleet.ProjectBootstrap.Supervisor
    )
  end
end
