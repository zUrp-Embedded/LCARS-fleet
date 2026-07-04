defmodule Fleet.Workflow.Application do
  @moduledoc """
  Application `fleet_workflow` — désormais une **lib workflow_map/gate/delivery** (quasi-pure).

  Il n'existe AUCUN moteur RAM (pas de `Fleet.Workflow.Executor` ni sa pile Registry/PodRegistry/
  ExecutorSupervisor, StageRunner, StageSpawner, Toposort, WorkspaceProvisioner) : aucun process n'est
  supervisé ici (l'orchestration vit sur le rail forge-state-machine). Le supervisor est donc **vide**
  — conservé transitoirement ; `fleet_workflow` tend vers du **lib-only** (sortie de la clé `mod:` de
  `mix.exs`). Le contenu réel est la lib consommée par le rail forge + 4 apps :
  `Loader` / `Gates` / `Gate` / `GateBrief` / `Deliverable` / `DeliverableGate` / `Git` / `Gatekeeper`.

  Pré-enregistre encore les atomes events `workflow_map.*` (plus émis, mais le Bus les autorise via
  `String.to_existing_atom/1`).
  """

  use Application

  @workflow_map_event_atoms [
    :"workflow_map.step.completed",
    :"workflow_map.completed",
    :"workflow_map.failed"
  ]

  @impl Application
  def start(_type, _args) do
    # Aucun process à superviser → supervisor vide. Conservé transitoirement (cible : lib-only).
    Supervisor.start_link([], strategy: :one_for_one, name: Fleet.Workflow.Supervisor)
  end

  @doc """
  Liste des atomes events `workflow_map.*` pré-enregistrés. Mitige le DoS par fuite d'atomes
  (le Bus n'accepte que des atomes déjà existants via `String.to_existing_atom/1`).
  """
  @spec workflow_map_event_atoms() :: [atom()]
  def workflow_map_event_atoms, do: @workflow_map_event_atoms
end
