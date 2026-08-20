defmodule Fleet.Observation.Application do
  @moduledoc """
  Supervisor for the read-only observation frontier: event projection plus the
  deck, served on a unix socket (the TCP port is gone — cf. `## The deck has no port`). Live pods come from the spawner; event-derived
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
  Child specs of the deck's Cowboy listener. Returns `[]` if `:start_listener` is `false`.

  ## The deck has no port, and that is the contract

  6-072/6-098. The observation deck used to bind a TCP port (`base+1`) published on the host's
  loopback. Every port published beside the landing is a SECOND ORIGIN, and a second origin is one
  nobody asks anything of: the landing verified a Gitea session, the deck behind it verified
  nothing. Removing the port removes the question — there is no other way in, so there is nothing
  else to discipline.

  The socket lives in the human's console directory (`2710 <human>:lcars-console`, setgid), beside
  `console.sock` and `pod.sock`. `connect(2)` requires traversing that directory, which only the
  human and the console group can do — the landing holds exactly that one supplementary group.

  `:ip` is no longer a contract to test: an AF_UNIX socket has no address to get wrong. What
  replaces it is the SOCKET'S mode, asserted below.
  """
  @spec listener_children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def listener_children do
    if Application.get_env(:lcars_fleet, :observation_start_listener, true) do
      # The binding gesture belongs to EventRouter — the only domain that declares `Plug.Cowboy`.
      # Writing it here compiled to `forbidden reference`, and that refusal was right: one place
      # knows how to bind Cowboy, so a second gesture cannot drift from the first.
      [{Fleet.EventRouter.UnixListener, plug: Fleet.Observation.Deck, socket: deck_socket()}]
    else
      []
    end
  end

  @doc """
  Where the deck listens. Per-human, beside the terminals' sockets — the landing derives the SAME
  path from the login it authenticated, so neither side carries a table of the other's.
  """
  def deck_socket do
    root = Application.get_env(:lcars_fleet, :console_sock_root, "/run/lcars/console")
    Path.join([root, human(), "deck.sock"])
  end

  # The BEAM runs AS the human (uid inheritance, no drop) — so its own user IS the routing key. A
  # config knob here would let the deck of one human land in another's directory, which the
  # directory's mode would then refuse, giving a "deck injoignable" with no visible cause.
  defp human do
    System.get_env("USER") || System.get_env("LOGNAME") || "lcars"
  end
end
