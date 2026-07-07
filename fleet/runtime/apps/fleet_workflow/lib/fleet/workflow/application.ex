defmodule Fleet.Workflow.Application do
  @moduledoc """
  Application `fleet_workflow` — now a **workflow_map/gate/delivery lib** (near-pure).

  There is NO in-memory (RAM) engine (no `Fleet.Workflow.Executor` nor its Registry/PodRegistry/
  ExecutorSupervisor, StageRunner, StageSpawner, Toposort, WorkspaceProvisioner stack): no process is
  supervised here (orchestration lives on the forge-state-machine rail). The supervisor is therefore **empty**
  — kept transitionally; `fleet_workflow` trends toward **lib-only** (dropping the `mod:` key from
  `mix.exs`). The real content is the lib consumed by the forge rail + 4 apps:
  `Loader` / `Gates` / `Gate` / `GateBrief` / `Deliverable` / `DeliverableGate` / `Git` / `Gatekeeper`.

  Still pre-registers the `workflow_map.*` event atoms (no longer emitted, but the Bus authorizes them via
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
    # No process to supervise → empty supervisor. Kept transitionally (target: lib-only).
    Supervisor.start_link([], strategy: :one_for_one, name: Fleet.Workflow.Supervisor)
  end

  @doc """
  List of pre-registered `workflow_map.*` event atoms. Mitigates atom-leak DoS
  (the Bus only accepts already-existing atoms via `String.to_existing_atom/1`).
  """
  @spec workflow_map_event_atoms() :: [atom()]
  def workflow_map_event_atoms, do: @workflow_map_event_atoms
end
