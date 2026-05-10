defmodule Fleet.PermissionRouter.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      if Application.get_env(:fleet_permission_router, :auto_start, false) do
        [{Fleet.PermissionRouter, []}]
      else
        []
      end

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fleet.PermissionRouter.Supervisor
    )
  end
end
