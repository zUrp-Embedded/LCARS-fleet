defmodule Fleet.Spawner.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Fleet.Spawner.Registry},
      Fleet.Spawner.Supervisor
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fleet.Spawner.RootSupervisor
    )
  end
end
