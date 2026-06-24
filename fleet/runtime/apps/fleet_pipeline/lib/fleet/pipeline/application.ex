defmodule Fleet.Pipeline.Application do
  @moduledoc """
  Application `fleet_pipeline` — désormais une **lib carte/gate/delivery** (quasi-pure).

  Il n'existe AUCUN moteur RAM (pas de `Fleet.Pipeline.Executor` ni sa pile Registry/PodRegistry/
  ExecutorSupervisor, StageRunner, StageSpawner, Toposort, WorkspaceProvisioner) : aucun process n'est
  supervisé ici (l'orchestration vit sur le rail forge-state-machine). Le supervisor est donc **vide**
  — conservé transitoirement ; `fleet_pipeline` tend vers du **lib-only** (sortie de la clé `mod:` de
  `mix.exs`). Le contenu réel est la lib consommée par le rail forge + 4 apps :
  `Loader` / `Gates` / `Gate` / `GateBrief` / `Deliverable` / `DeliverableGate` / `Git` / `Gatekeeper`.

  Pré-enregistre encore les atomes events `pipeline.*` (plus émis, mais le Bus les autorise via
  `String.to_existing_atom/1`).
  """

  use Application

  @pipeline_event_atoms [
    :"pipeline.stage.completed",
    :"pipeline.completed",
    :"pipeline.failed"
  ]

  @impl Application
  def start(_type, _args) do
    # Aucun process à superviser → supervisor vide. Conservé transitoirement (cible : lib-only).
    Supervisor.start_link([], strategy: :one_for_one, name: Fleet.Pipeline.Supervisor)
  end

  @doc """
  Liste des atomes events `pipeline.*` pré-enregistrés. Mitige le DoS par fuite d'atomes
  (le Bus n'accepte que des atomes déjà existants via `String.to_existing_atom/1`).
  """
  @spec pipeline_event_atoms() :: [atom()]
  def pipeline_event_atoms, do: @pipeline_event_atoms
end
