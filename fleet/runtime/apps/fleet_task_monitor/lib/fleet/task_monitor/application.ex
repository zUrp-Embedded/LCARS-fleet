defmodule Fleet.TaskMonitor.Application do
  @moduledoc """
  Application supervisor `fleet_task_monitor`.

  `Fleet.TaskMonitor` GenServer démarré **config-gated** :
  `:fleet_task_monitor, :start_monitor` (défaut `false`). Le service
  systemd `lcars-fleet.service` l'active en prod ; tests/CI
  l'instancient directement avec opts isolés (tmp_dir, name unique,
  `subscribe: false`) → suite async-safe.

  Pattern gate cohérent `fleet_event_router` (`:start_dispatch`
  défaut false). `:one_for_one`.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      if Application.get_env(:fleet_task_monitor, :start_monitor, false) do
        [Fleet.TaskMonitor]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Fleet.TaskMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
