defmodule Fleet.TaskQueue.Application do
  @moduledoc false
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # Il y avait ici un `persist: false` explicite, et le commentaire qui l'accompagnait plaidait
    # qu'il etait « UNE DECISION, PAS UN OUBLI » — parce que la machinerie `Store` restait intacte
    # derriere, et que rien ne disait laquelle des deux etait l'accident. Le rail est retire
    # (BL-6-113) : il n'y a plus de choix a declarer, donc plus de plaidoirie a lire. Le broker est
    # ephemere par construction.
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
