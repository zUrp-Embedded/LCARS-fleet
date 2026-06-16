defmodule Fleet.Pipeline.Application do
  @moduledoc """
  Application `fleet_pipeline` — désormais une **lib carte/gate/delivery** (quasi-pure).

  Le moteur RAM (`Fleet.Pipeline.Executor` + sa pile : Registry/PodRegistry/ExecutorSupervisor,
  StageRunner, StageSpawner, Toposort, WorkspaceProvisioner) a été RETIRÉ (②.3 / BL-050, 2026-06-16) :
  il ne reste plus AUCUN process à superviser ici. Le supervisor est donc **vide** — conservé
  transitoirement ; `fleet_pipeline` est destiné à devenir `fleet_core` **lib-only** (Bloc C, sortie de
  la clé `mod:` de `mix.exs`). Les survivants sont la lib consommée par le rail forge + 4 apps :
  `Loader` / `Gates` / `Gate` / `GateBrief` / `Deliverable` / `DeliverableGate` / `Git` / `Gatekeeper`.

  Pré-enregistre encore les atomes events `pipeline.*` (legacy Executor ; plus émis, mais le Bus les
  autorise via `String.to_existing_atom/1` — nettoyage en Bloc C).
  """

  use Application

  @pipeline_event_atoms [
    :"pipeline.stage.completed",
    :"pipeline.completed",
    :"pipeline.failed"
  ]

  @impl Application
  def start(_type, _args) do
    # Plus aucun process (moteur RAM retiré) → supervisor vide. Conservé transitoirement (Bloc C : lib-only).
    Supervisor.start_link([], strategy: :one_for_one, name: Fleet.Pipeline.Supervisor)
  end

  @doc """
  Liste des atomes events `pipeline.*` pré-enregistrés (legacy Executor). Cohérent ch11 M1
  atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).
  """
  @spec pipeline_event_atoms() :: [atom()]
  def pipeline_event_atoms, do: @pipeline_event_atoms
end
