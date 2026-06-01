defmodule Fleet.TaskQueue.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    children = [Fleet.TaskQueue.Server]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      name: Fleet.TaskQueue.Supervisor
    )
  end
end
