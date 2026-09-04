defmodule Fleet.TaskQueue.Application do
  @moduledoc false
  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # Le broker est EPHEMERE PAR CONSTRUCTION (BL-6-113) : pas de rail de persistance, donc pas de
    # drapeau a poser ni de choix a plaider ici. L'AUTORITE est le `@moduledoc` de
    # `Fleet.TaskQueue.Server` (la forge est la verite du travail, le broker n'en est que le FRONT
    # RAM). On POINTE, on ne recopie pas.
    children = [Fleet.TaskQueue.Server]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
