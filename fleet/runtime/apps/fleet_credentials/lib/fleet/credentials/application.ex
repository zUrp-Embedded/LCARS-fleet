defmodule Fleet.Credentials.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Fleet.Credentials.OAuthRefresher.Supervisor, []}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Fleet.Credentials.RootSupervisor
    )
  end
end
