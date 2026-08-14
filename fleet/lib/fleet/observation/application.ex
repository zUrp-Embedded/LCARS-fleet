defmodule Fleet.Observation.Application do
  @moduledoc """
  Supervisor for the read-only observation frontier: event projection plus a
  dedicated loopback Cowboy deck. Live pods come from the spawner; event-derived
  views come from `ReadModel`.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = readmodel_children() ++ listener_children()

    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    ]

    Supervisor.init(children, opts)
  end

  # Tests start the sole Bus subscriber explicitly.
  defp readmodel_children do
    if Application.get_env(:lcars_fleet, :observation_start_readmodel, true) do
      [Fleet.Observation.ReadModel]
    else
      []
    end
  end

  @doc """
  Child specs of the deck's Cowboy listener (public for the bind test: the `:ip`
  is a contract — loopback by default). Returns `[]` if `:start_listener` is `false`.
  """
  def listener_children do
    if Application.get_env(:lcars_fleet, :observation_start_listener, true) do
      port = Application.fetch_env!(:lcars_fleet, :observation_http_port)

      [Fleet.EventRouter.Listener.cowboy_child(plug: Fleet.Observation.Deck, port: port)]
    else
      []
    end
  end
end
