defmodule Fleet.TaskQueue.Application do
  @moduledoc false
  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # Server restarts empty; forge-driven callers reconstruct work, not a broker state file.
    children = [Fleet.TaskQueue.Server]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
