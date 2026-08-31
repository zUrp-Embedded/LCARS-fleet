defmodule Fleet.EventRouter.UnixListener do
  @moduledoc """
  Binds a Plug on an AF_UNIX socket and announces readiness only once the socket's mode is right.

  ## What this module adds, and what it deliberately does NOT

  It adds the LIFECYCLE an AF_UNIX listener needs and a TCP one does not: removing a stale socket
  before binding, committing readiness only after the mode is right, and removing the file on the
  way out. It does NOT build the child spec — `Fleet.EventRouter.Listener.cowboy_child/1` does, and
  it is the single builder in this runtime.

  Three walls hold that separation, and the third is the one that matters: `Plug.Cowboy.child_spec/1`
  called from `Fleet.Observation` is a boundary `forbidden reference` (that domain does not declare
  Plug.Cowboy), the same call from here is refused for the same reason, and a hand-written Cowboy
  child-spec tuple is refused by `mix lcars.contracts.check`, rail `listener.no_cowboy_bypass`,
  whose own remediation says to route through the builder. With two builders the second drifts, and
  the first is loopback-by-construction for a reason.

  ⚠ The rail greps for the literal tuple opening and strips only `#` comments — a docstring is not
  stripped. So this prose must DESCRIBE that tuple, never spell it, or the module documenting the
  rail would be the one tripping it. The rail's own header carries the same warning about itself.

  ## Why an AF_UNIX listener exists at all

  6-072/6-098. A published TCP port is an ORIGIN, and an origin is something a browser can reach
  without passing the door that authenticated anyone. A socket under a directory nobody can traverse
  is not reachable at all — the protection stops being a rule somebody has to remember to apply and
  becomes a property of the topology.

  ## Why the mode is a parameter

  Its one caller in `lib/`, the observation deck, takes the `0o660` default: the landing — a
  DIFFERENT uid holding the console group — must open the socket. `0600`, which is what a socket
  only the BEAM's own owner may open wants, is the other value the knob exists for. The directory
  is what keeps everyone else out; the file mode only arbitrates between the owner and that group.

  ## Readiness is committed after the chmod, never before

  A socket that exists with the wrong mode is worse than an absent one: the deck is up, the caller
  gets `EACCES`, and every diagnostic points at the network. So a failed chmod tears the listener
  down and removes the socket rather than announcing a door nobody can open.
  """

  use GenServer
  require Logger

  @doc """
  Child spec. Options: `:plug` and `:socket` (required), `:mode` (default `0o660`), `:chmod_fun`
  and `:id` (tests).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl GenServer
  def init(opts) do
    plug = Keyword.fetch!(opts, :plug)
    sock = Keyword.fetch!(opts, :socket)
    mode = Keyword.get(opts, :mode, 0o660)
    chmod_fun = Keyword.get(opts, :chmod_fun, &File.chmod/2)

    _ = File.mkdir_p(Path.dirname(sock))
    # A stale socket file outlives the process that made it and blocks the bind. With a port the
    # kernel reclaims the resource; with a file, nobody does — so a clean restart needs this.
    _ = File.rm(sock)

    # ⚠ LA SPEC VIENT DU CONSTRUCTEUR UNIQUE. Ni un `{Plug.Cowboy, ...}` ecrit a la main (refuse par
    # `listener.no_cowboy_bypass`), ni un appel direct a `Plug.Cowboy.child_spec/1` (refuse par la
    # boundary : ce domaine ne DECLARE pas Plug.Cowboy) — les trois murs sont dans le @moduledoc.

    # `:ref` is unique per start ON PURPOSE: Ranch cleans a previous listener up asynchronously, so a
    # restart that reused the name could collide with its own predecessor.
    ref = {__MODULE__, System.unique_integer([:positive])}

    spec = Fleet.EventRouter.Listener.cowboy_child(plug: plug, socket: sock, ref: ref)

    case Supervisor.start_link([spec], strategy: :one_for_one) do
      {:ok, pid} ->
        case chmod_fun.(sock, mode) do
          :ok ->
            Logger.info(
              "UnixListener: #{inspect(plug)} bound at #{sock} " <>
                "(AF_UNIX, mode #{Integer.to_string(mode, 8)}, no port)"
            )

            {:ok, %{pid: pid, sock: sock, plug: plug}}

          {:error, reason} ->
            Logger.error(
              "UnixListener: #{inspect(plug)} bound at #{sock} but chmod " <>
                "#{Integer.to_string(mode, 8)} FAILED (#{inspect(reason)}) — tearing the listener " <>
                "down and removing the socket (a door nobody can open is never announced ready)"
            )

            _ = Supervisor.stop(pid)
            _ = File.rm(sock)
            {:stop, {:chmod_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, %{sock: sock}) do
    # The socket is a FILE: leaving it behind makes the next boot look like a port conflict.
    _ = File.rm(sock)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
