defmodule Fleet.IPCFilter.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = []

    if Application.get_env(:fleet_ipc_filter, :auto_init, false) do
      Fleet.IPCFilter.init_patterns!()
    end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fleet.IPCFilter.Supervisor
    )
  end
end
