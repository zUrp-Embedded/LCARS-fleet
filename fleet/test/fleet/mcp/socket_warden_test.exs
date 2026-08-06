defmodule Fleet.MCP.SocketWardenTest do
  @moduledoc """
  The RUNTIME net for orphaned MCP sockets.

  `release_pod_socket/1` runs in the pod's `terminate/3` — which a BRUTAL kill (wedged tmux
  teardown, kill -9) NEVER executes: acceptor + AF_UNIX listener + Registry entry + file would
  outlive their pod until the BEAM reboots (the cold-boot sweep only covers boot). tmux and
  pod_dirs have their warden; sockets need theirs too. This warden closes the asymmetry — by
  reconciling, never by guessing.
  """
  use ExUnit.Case, async: true

  alias Fleet.MCP.SocketWarden

  defp start_warden(opts) do
    start_supervised!({SocketWarden, [name: nil, tick_ms: 10] ++ opts})
  end

  test "socket whose pod has VANISHED → reclaimed, but only at the 2nd tick (grace)" do
    parent = self()

    start_warden(
      owned_fun: fn -> ["pod-ghost", "pod-live"] end,
      live_pods_fun: fn -> ["pod-live"] end,
      release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
    )

    # 1st tick: suspect. 2nd tick: orphan CONFIRMED → release. The grace exists because
    # `ensure_pod_socket` runs during :projecting — a socket can legitimately exist for a few
    # moments before the pod registers. Reclaiming on the 1st hit would kill the socket of a
    # pod being born.
    assert_receive {:released, "pod-ghost"}, 1_000
    refute_received {:released, "pod-live"}
  end

  test "live-pod enumeration FAILING → NOTHING reclaimed (a reconciliation does not become the outage it prevents)" do
    parent = self()

    warden =
      start_warden(
        owned_fun: fn -> ["pod-a", "pod-b"] end,
        live_pods_fun: fn -> raise "spawner unavailable" end,
        release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
      )

    # An empty live-set would make ALL sockets look orphaned: the fail-safe returns
    # :error → no release, the suspects' state is preserved.
    refute_receive {:released, _}, 200
    assert Process.alive?(warden)
  end

  test "every socket has its pod alive → no release (clean = silent)" do
    parent = self()

    start_warden(
      owned_fun: fn -> ["pod-a", "pod-b"] end,
      live_pods_fun: fn -> ["pod-a", "pod-b"] end,
      release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
    )

    refute_receive {:released, _}, 200
  end

  test "a pod COMING BACK between the two ticks is NOT reclaimed (the grace protects the race)" do
    parent = self()
    counter = :counters.new(1, [])

    start_warden(
      owned_fun: fn -> ["pod-slow"] end,
      live_pods_fun: fn ->
        # 1st tick: the pod is not registered yet (it is projecting) → suspect.
        # Following ticks: it is there → the orphan is never CONFIRMED.
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: [], else: ["pod-slow"]
      end,
      release_fun: fn pod_id -> send(parent, {:released, pod_id}) && :ok end
    )

    refute_receive {:released, "pod-slow"}, 300
  end
end
