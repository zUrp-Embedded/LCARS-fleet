defmodule Fleet.ClaudeBridge.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = []

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fleet.ClaudeBridge.RootSupervisor
    )
  end
end
