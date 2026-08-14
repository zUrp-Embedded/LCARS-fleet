defmodule Fleet.TaskQueue.Application do
  @moduledoc false
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # `persist: false` EST UNE DECISION, PAS UN OUBLI, et elle se lisait ici comme un oubli : un
    # lecteur qui atterrit sur ce fichier voit une file dont la persistance est coupee, avec la
    # machinerie `Store` intacte derriere, et rien ne lui dit laquelle des deux est l'accident.
    # L'AUTORITE est le `@moduledoc` de `Fleet.TaskQueue.Server` (axiome de source unique : la forge
    # est la verite du travail, le broker n'en est que le FRONT RAM ; aucun champ n'est
    # broker-only-durable, donc au redemarrage la file se re-derive des polls plutot que de
    # ressusciter des mandats que la forge a depuis depasses). On POINTE, on ne recopie pas.
    children = [{Fleet.TaskQueue.Server, persist: false}]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
