defmodule Fleet.TaskQueue.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    # AXIOME source-unique : la FORGE est la vérité du travail (issues/routes/PR). Le broker est son
    # FRONT en RAM, pas un 2e dépositaire. Rien dans le work item n'est broker-only-durable (tout est
    # re-dérivable au re-dispatch forge) → le broker tourne ÉPHÉMÈRE (`persist: false`) : zéro `state.json`
    # → impossible d'accumuler des tâches stale persistées (cause des 1124 "en cours" cross-reboot). Au
    # restart, la queue se re-dérive des polls forge (le rail de réconciliation canonique). La persistance
    # reste opt-in (mécanisme testé) pour un futur état broker-only-durable — il n'en existe AUCUN à ce jour.
    children = [{Fleet.TaskQueue.Server, persist: false}]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      name: Fleet.TaskQueue.Supervisor
    )
  end
end
