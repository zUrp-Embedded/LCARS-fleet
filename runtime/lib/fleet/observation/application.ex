defmodule Fleet.Observation.Application do
  @moduledoc """
  Supervises optional event projection and the observation deck's UNIX listener.
  Live pods come from Spawner; event-derived views come from ReadModel.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
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
  Returns the UNIX listener child unless :observation_start_listener is false.
  The deck relies on landing authentication and filesystem access, not its own
  session check. Deployment uses a per-human 2710 <human>:lcars-console directory
  and gives the landing the console group; this function does not enforce that setup.
  """
  @spec listener_children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def listener_children do
    if Application.get_env(:lcars_fleet, :observation_start_listener, true) do
      # UnixListener owns the shared Cowboy binding implementation.
      [{Fleet.EventRouter.UnixListener, plug: Fleet.Observation.Deck, socket: deck_socket()}]
    else
      []
    end
  end

  @doc """
  Builds <console_sock_root>/<human>/deck.sock, matching the landing's routing layout.
  human comes from USER, then LOGNAME, then lcars; it is not checked against the UID.
  """
  @spec deck_socket() :: String.t()
  def deck_socket do
    root = Application.get_env(:lcars_fleet, :console_sock_root, "/run/lcars/console")
    Path.join([root, human(), "deck.sock"])
  end

  defp human do
    System.get_env("USER") || System.get_env("LOGNAME") || "lcars"
  end
end
