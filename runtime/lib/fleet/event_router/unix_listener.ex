defmodule Fleet.EventRouter.UnixListener do
  @moduledoc """
  Owns AF_UNIX startup around Listener.cowboy_child/1: removes the old path, starts
  Cowboy, then applies mode before logging readiness and completing init. Returned chmod
  errors stop the child supervisor and attempt socket removal; chmod exceptions are not caught.

  A filesystem socket avoids a browser-reachable TCP origin. The caller must provision a
  trusted parent directory and appropriate owner/group. Default 0o660 lets the observation
  landing's console group connect; 0o600 restricts access to the owner. This module neither
  sets directory permissions nor validates ownership. Binding precedes chmod, so parent
  permissions also matter during startup.

  Initial mkdir/removal errors are ignored. terminate/2 attempts path removal when invoked;
  it does not explicitly stop the linked child supervisor or guarantee cleanup on every exit.
  Use a dedicated path: stale cleanup does not verify the existing file is a socket.

  listener.no_cowboy_bypass enforces the shared builder. Its textual scan includes docstrings,
  so do not spell a raw Cowboy child-spec tuple here; Boundary also rejects direct construction.
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
    # A stale filesystem entry can block rebinding after its listener has died.
    _ = File.rm(sock)

    # Unique ref avoids Ranch-name collisions while a previous listener is still cleaning up.
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
    _ = File.rm(sock)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
