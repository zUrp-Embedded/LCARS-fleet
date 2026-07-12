defmodule Fleet.TaskQueue.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    # Single-source AXIOM: the FORGE is the truth of work (issues/routes/PR). The broker is its
    # RAM FRONT, not a 2nd store of record. Nothing in the work item is broker-only-durable (everything is
    # re-derivable on forge re-dispatch) → the broker runs EPHEMERAL (`persist: false`): zero `state.json`
    # → no way to accumulate persisted stale tasks (the cause of the accumulated "in-progress" ones cross-reboot). On
    # restart, the queue re-derives itself from forge polls (the canonical reconciliation rail). Persistence
    # stays opt-in (tested mechanism) for a future broker-only-durable state — NONE exists to date.
    children = [{Fleet.TaskQueue.Server, persist: false}]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      name: Fleet.TaskQueue.Supervisor
    )
  end
end
