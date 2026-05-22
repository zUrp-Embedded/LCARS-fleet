defmodule Fleet.ProjectBootstrap.Application do
  @moduledoc """
  Application supervisor `fleet_project_bootstrap` (Lot 2 — Ring 1, core du pod).

  DN : `ring1/fleet_project_bootstrap.md`.

  `Fleet.ProjectBootstrap.prepare/3` + les 5 sous-phases (Allocate / Clone /
  InitMimic / BindCredentials / PrepareMountBinds) sont des **fonctions pures**
  (File / Path / git / :eex) — aucun process raison runtime (Iron Law :
  pas d'état mutable persistant, pas de concurrence interne, pas de fault
  isolation propre). Invoqué synchroniquement par `Fleet.Spawner.Pod` phase
  PROJECT (chantier 6 PROMOTED).

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
