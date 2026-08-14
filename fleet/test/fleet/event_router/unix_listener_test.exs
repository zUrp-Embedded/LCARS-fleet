defmodule Fleet.EventRouter.UnixListenerTest do
  @moduledoc """
  `Fleet.EventRouter.UnixListener` — 6-072/6-098.

  ## What is worth pinning here

  Binding is the easy half. The half that matters is the ORDER: readiness is committed only after
  the mode is right. A socket that exists with the wrong mode is worse than an absent one — the
  service is up, the caller gets `EACCES`, and every diagnostic points at the network instead of at
  a file mode. So a failed chmod must leave NOTHING behind.

  `async: false`: these tests bind real sockets and start real Ranch trees.

  ⚠ SOCKET PATHS LIVE UNDER A SHORT `/tmp` ROOT, not under `tmp_dir`. `sun_path` is capped at 108
  bytes (measured in the image: 107 binds, 108 refuses), and ExUnit's per-test directory is deep
  enough to cross it — the bind then fails for a reason that has nothing to do with the test.
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
    # The low 12 bits are the permission bits; the rest is the file type (S_IFSOCK).
    assert Bitwise.band(mode, 0o777) == 0o660
  end

  test "the mode is a PARAMETER — the two callers want different ones", %{sock: sock} do
    # ControlRouter's control socket is owner-only (0600); this deck's is group-writable (0660)
    # because the landing runs as a different uid holding the console group. Hard-coding either
    # would force the other caller to work around it.
    start!(plug: EchoPlug, socket: sock, mode: 0o600)

    %File.Stat{mode: mode} = File.stat!(sock)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "a stale socket file does NOT block a restart", %{sock: sock} do
    # With a port the kernel reclaims the resource; with a file, nobody does. A leftover socket from
    # a killed BEAM would make every subsequent boot fail on a bind that looks like a port conflict.
    File.mkdir_p!(Path.dirname(sock))
    File.write!(sock, "residu")

    start!(plug: EchoPlug, socket: sock)
    assert get_over(sock) =~ "unix-ok"
  end

  test "chmod refused → the listener REFUSES to start and leaves no socket behind", %{sock: sock} do
    # THE PROPERTY THIS MODULE EXISTS FOR. Without it, the deck is up, the socket is there, the
    # landing cannot open it, and the operator reads "deck injoignable" — a network verdict for a
    # file mode. Starting is not the same as being reachable, and only one of the two may be
    # announced.
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
    # Without this, a listener that refused to start under ALL circumstances would pass the test
    # above. The injected fun is the only difference between the two.
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
    # Started OUTSIDE the ExUnit supervisor on purpose: this test is about what `terminate/2` does,
    # so it must own the stop rather than hand it to a harness that would also tear down the tmp
    # directory and hide the answer.
    {:ok, pid} = UnixListener.start_link(plug: EchoPlug, socket: sock)
    assert File.exists?(sock)

    :ok = GenServer.stop(pid)
    refute File.exists?(sock)
  end
end
