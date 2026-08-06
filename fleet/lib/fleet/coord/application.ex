defmodule Fleet.Coord.Application do
  @moduledoc """
  Loads coordination policies fail-fast, then supervises the process-free domain.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    :ok = Fleet.Coord.Policies.init_policies!()

    children = []

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
