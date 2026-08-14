defmodule Fleet.EventRouter.UnixListener do
  @moduledoc """
  Binds a Plug on an AF_UNIX socket and announces readiness only once the socket's mode is right.

  ## Why this lives in EventRouter and not next to its caller

  This domain already owns HTTP listener construction (`Fleet.EventRouter.Listener.cowboy_child/1`)
  and it is the only one that declares `Plug.Cowboy`. The first draft of this listener was written
  inside `Fleet.Observation`, and the compiler refused it — `forbidden reference to Plug.Cowboy`.
  That refusal is the architecture speaking, not an obstacle: ONE place knows how to bind Cowboy, so
  a second binding gesture cannot drift from the first. The fix was to move the code here, not to
  widen the boundary.

  ## Why an AF_UNIX listener exists at all

  6-072/6-098. A published TCP port is an ORIGIN, and an origin is something a browser can reach
  without passing the door that authenticated anyone. A socket under a directory nobody can traverse
  is not reachable at all — the protection stops being a rule somebody has to remember to apply and
  becomes a property of the topology.

  ## The mode is a parameter, and the two callers want different ones

  `Fleet.API.ControlRouter` binds `0600`: only the BEAM's own owner opens it. This module's first
  caller (the observation deck) binds `0660`, because the landing — a DIFFERENT uid holding the
  console group — must open it. The directory is what keeps everyone else out; the file mode only
  arbitrates between the owner and that one group.

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
  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

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

    # ⚠ ON CONSTRUIT UNE SPEC, ON N'APPELLE PAS `Plug.Cowboy` — et c'est l'idiome de ce domaine, pas
    # un detour. `Fleet.EventRouter` ne DECLARE pas `Plug.Cowboy` dans sa boundary : son
    # `cowboy_child/1` rend lui aussi un tuple. Seul `Fleet.API` le declare, parce que
    # `ControlRouter` l'appelle vraiment. La premiere version de ce module appelait
    # `Plug.Cowboy.child_spec/1` et le compilateur a refuse deux fois de suite — d'abord depuis
    # Observation, puis depuis ici. Le refus disait a chaque fois la meme chose : ce domaine n'a pas
    # a connaitre le serveur, il a a decrire un enfant.
    spec =
      {Plug.Cowboy,
       scheme: :http,
       plug: plug,
       # A unique ref isolates this start from a predecessor's asynchronous Ranch cleanup.
       options: [
         ip: {:local, sock},
         port: 0,
         ref: {__MODULE__, System.unique_integer([:positive])}
       ]}

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
