defmodule Fleet.TaskQueue.Application do
  # Superviseur de domaine (ex-callback Application de l'app umbrella — collapse Z2
  # migration 2026-07-12 ; nom conservé pour zéro churn de références).
  # @moduledoc false RESTAURÉ : module interne délibérément caché (le contrat public
  # du domaine vit dans la façade Fleet.TaskQueue) — la conversion ne change pas ça.
  @moduledoc false
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # Single-source AXIOM: the FORGE is the truth of work (issues/routes/PR). The broker is its
    # RAM FRONT, not a 2nd store of record. Nothing in the work item is broker-only-durable (everything is
    # re-derivable on forge re-dispatch) → the broker runs EPHEMERAL (`persist: false`): zero `state.json`
    # → no way to accumulate persisted stale tasks (the cause of the accumulated "in-progress" ones cross-reboot). On
    # restart, the queue re-derives itself from forge polls (the canonical reconciliation rail). Persistence
    # stays opt-in (tested mechanism) for a future broker-only-durable state — NONE exists to date.
    children = [{Fleet.TaskQueue.Server, persist: false}]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
