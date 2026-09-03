defmodule Fleet.TaskQueue.Application do
  @moduledoc false
  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # Pas de `persist: false` a declarer ici : le broker est EPHEMERE PAR CONSTRUCTION, il n'y a
    # pas de rail de persistance derriere (BL-6-113) et donc pas de choix a plaider. Un drapeau
    # accompagne d'un commentaire jurant qu'il est « une decision, pas un oubli » signale surtout
    # qu'une machinerie intacte subsiste a cote, et que rien ne dit laquelle des deux est
    # l'accident.
    #
    # L'AUTORITE reste le `@moduledoc` de `Fleet.TaskQueue.Server` (axiome de source unique : la
    # forge est la verite du travail, le broker n'en est que le FRONT RAM). On POINTE, on ne recopie
    # pas.
    children = [Fleet.TaskQueue.Server]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
