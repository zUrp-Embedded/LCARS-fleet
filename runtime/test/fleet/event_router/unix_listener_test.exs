defmodule Fleet.EventRouter.UnixListenerTest do
  @moduledoc """
  Real AF_UNIX/Ranch checks for service, mode and socket-path cleanup. They do not prove
  cross-UID access, absence of a pre-chmod connection window or child-tree shutdown.
  Keep paths short under /tmp: this Linux image accepts at most 107 pathname bytes;
  ExUnit's test-derived directories can exceed the socket address limit.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.UnixListener

  defmodule EchoPlug do
    @behaviour Plug
    @impl true
    def init(o), do: o
    @impl true
    def call(conn, _o), do: Plug.Conn.send_resp(conn, 200, "unix-ok")
  end

  setup do
    root = Path.join("/tmp", "ul#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, sock: Path.join(root, "d.sock")}
  end

  defp start!(opts) do
    start_supervised!(%{
      id: {UnixListener, System.unique_integer([:positive])},
      start: {UnixListener, :start_link, [opts]}
    })
  end

  # A raw HTTP/1.1 exchange over AF_UNIX: what proves the listener SERVES, not merely that a file
  # with the right mode appeared.
  defp get_over(sock) do
    {:ok, s} = :gen_tcp.connect({:local, sock}, 0, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(s, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    {:ok, data} = :gen_tcp.recv(s, 0, 5_000)
    :gen_tcp.close(s)
    data
  end

  test "binds, serves the plug, and the socket carries mode 0660", %{sock: sock} do
    start!(plug: EchoPlug, socket: sock)

    assert File.exists?(sock)
    assert get_over(sock) =~ "unix-ok"

    %File.Stat{mode: mode} = File.stat!(sock)
    # Mask the nine rwx bits; this does not check special mode bits or file type.
    assert Bitwise.band(mode, 0o777) == 0o660
  end

  test "the mode is a PARAMETER — the two callers want different ones", %{sock: sock} do
    # Parameter supports owner-only mode alongside the deck's group-access default.
    start!(plug: EchoPlug, socket: sock, mode: 0o600)

    %File.Stat{mode: mode} = File.stat!(sock)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "a stale socket file does NOT block a restart", %{sock: sock} do
    # The stale-path fixture is a regular file, not a leftover bound socket.
    File.mkdir_p!(Path.dirname(sock))
    File.write!(sock, "residu")

    start!(plug: EchoPlug, socket: sock)
    assert get_over(sock) =~ "unix-ok"
  end

  test "chmod refused → the listener REFUSES to start and leaves no socket behind", %{sock: sock} do
    # Inject a returned chmod error; do not announce success with unusable permissions.
    Process.flag(:trap_exit, true)

    assert {:error, {:chmod_failed, :eperm}} =
             UnixListener.start_link(
               plug: EchoPlug,
               socket: sock,
               chmod_fun: fn _p, _m -> {:error, :eperm} end
             )

    refute File.exists?(sock),
           "a socket nobody can open was left behind — the next boot would serve it"
  end

  test "TEMOIN: the same start SUCCEEDS when chmod succeeds", %{sock: sock} do
    # Positive control against unconditional refusal. This stub does not actually change mode.
    pid =
      start_supervised!(%{
        id: :ok_case,
        start:
          {UnixListener, :start_link,
           [[plug: EchoPlug, socket: sock, chmod_fun: fn _p, _m -> :ok end]]}
      })

    assert Process.alive?(pid)
    assert File.exists?(sock)
  end

  test "the socket is removed on shutdown — the next boot must not look like a conflict", %{
    sock: sock
  } do
    # Stop explicitly before fixture cleanup so the harness cannot hide a leftover path.
    # No assertion checks whether the linked Ranch supervisor also stopped.
    {:ok, pid} = UnixListener.start_link(plug: EchoPlug, socket: sock)
    assert File.exists?(sock)

    :ok = GenServer.stop(pid)
    refute File.exists?(sock)
  end
end
