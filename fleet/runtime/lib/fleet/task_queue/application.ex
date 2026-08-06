defmodule Fleet.TaskQueue.Application do
  @moduledoc false
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = [{Fleet.TaskQueue.Server, persist: false}]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
