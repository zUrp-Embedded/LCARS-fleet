defmodule Fleet.Spawner.Pod.LivenessTest do
  @moduledoc """
  liveness_moved?/2 is TRI-STATE: an unobservable sample (both signals nil) is a
  measurement gap, not proven silence — it must re-arm the deadline (benefit of the doubt),
  never accumulate toward the kill of a pod we could not measure.
  """
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.Liveness

  test "no baseline (first tick) → moved (alive)" do
    assert Liveness.liveness_moved?(nil, {10, 5})
  end

  test "a growing signal → moved (jsonl OR cpu)" do
    assert Liveness.liveness_moved?({10, 5}, {11, 5})
    assert Liveness.liveness_moved?({10, 5}, {10, 6})
  end

  test "genuine silence (at least one signal readable, neither grew) → NOT moved" do
    refute Liveness.liveness_moved?({10, 5}, {10, 5})
    refute Liveness.liveness_moved?({10, nil}, {10, nil})
    refute Liveness.liveness_moved?({nil, 5}, {nil, 5})
  end

  test "UNOBSERVABLE new sample (both nil) → moved (re-probe), never counted as silence" do
    # The bug: a stat + /proc double-failure read as {nil, nil} → not moved → accumulated
    # toward the kill, destroying a pod we simply could not measure. Unknown ≠ silent.
    assert Liveness.liveness_moved?({10, 5}, {nil, nil})
    assert Liveness.liveness_moved?({nil, nil}, {nil, nil})
  end

  test "3-tuple probe (pane hash): a pane CHANGE alone is movement — the in-generation signal" do
    # jsonl frozen between message boundaries + holder cpu idle + TUI repainting = alive.
    assert Liveness.liveness_moved?({10, 5, 111}, {10, 5, 222})
    # Static screen + frozen signals = genuine silence.
    refute Liveness.liveness_moved?({10, 5, 111}, {10, 5, 111})
    # A nil hash on either side proves nothing (capture failure never counts as movement).
    refute Liveness.liveness_moved?({10, 5, nil}, {10, 5, 333})
    refute Liveness.liveness_moved?({10, 5, 111}, {10, 5, nil})
    # The other signals still carry alone.
    assert Liveness.liveness_moved?({10, 5, 111}, {11, 5, 111})
    # Fully unobservable 3-tuple = unknown, never proven silence.
    assert Liveness.liveness_moved?({10, 5, 111}, {nil, nil, nil})
    assert Liveness.unobservable?({nil, nil, nil})
  end

  test "unobservable?/1 flags the fully-nil sample (the tick handler logs the degrade)" do
    assert Liveness.unobservable?({nil, nil})
    refute Liveness.unobservable?({10, nil})
    refute Liveness.unobservable?({nil, 5})
    refute Liveness.unobservable?({10, 5})
  end

  # ── 4th signal: the pod's last COMPLETED MCP tool call ──────────────────────────────────────────
  #
  # It is the only signal of the four that PROVES activity: the other three observe the pod's
  # surroundings (a file grows, a process burns cpu, a screen repaints) and infer. An MCP call is
  # the pod acting. It is also the only one that survives a pod with no readable tmux pane.

  test "4-tuple: the MCP marker ALONE is movement — a pod whose only sign of life is talking to us" do
    assert Liveness.liveness_moved?({10, 5, 42, 1_700_000_000}, {10, 5, 42, 1_700_000_030})
  end

  test "4-tuple: a marker that stops moving contributes NOTHING (an old call is not a live pod)" do
    # The trap this closes: an mtime is a timestamp, so it is TEMPTING to read it as "was alive
    # recently". It goes through `grew?` like the counters — only a NEW call since the last tick
    # counts, otherwise a pod that made one tool call and died would read alive forever.
    refute Liveness.liveness_moved?({10, 5, 42, 1_700_000_000}, {10, 5, 42, 1_700_000_000})
  end

  test "4-tuple fully nil → UNOBSERVABLE, so moved (re-probe), and flagged for the degrade log" do
    assert Liveness.liveness_moved?({1, 1, 1, 1}, {nil, nil, nil, nil})
    assert Liveness.unobservable?({nil, nil, nil, nil})
  end

  test "4-tuple: a nil marker proves nothing either way (absence of MCP is not silence)" do
    refute Liveness.liveness_moved?({10, 5, 42, nil}, {10, 5, 42, nil})
    assert Liveness.liveness_moved?({10, 5, 42, nil}, {11, 5, 42, nil})
  end

  # THE CLAUSE THAT MUST NEVER KILL. The tuple grew 2 -> 3 -> 4 signals over the life of this
  # module; each growth makes a MISMATCHED pair reachable (the tick that straddles the change, or a
  # test probe of another shape). Before the 4th signal that pair raised FunctionClauseError inside
  # the liveness tick — the one place where failing to observe must never be fatal.
  test "sample shapes of DIFFERENT arity are UNKNOWN, not a crash and not silence" do
    assert Liveness.liveness_moved?({10, 5, 42}, {10, 5, 42, 1_700_000_000})
    assert Liveness.liveness_moved?({10, 5, 42, 1_700_000_000}, {10, 5, 42})
    assert Liveness.liveness_moved?({10, 5}, {10, 5, 42, 1_700_000_000})
    assert Liveness.liveness_moved?(:garbage, {10, 5, 42, 1_700_000_000})
  end

  test "the marker path is derived from the SOCKET path — one name, two domains" do
    # MCP writes it, the spawner reads it, and neither may call the other: the name lives once, in
    # foundation. Two definitions of one filename is a drift waiting for the first edit.
    assert Fleet.Layout.pod_mcp_activity_marker("/run/mcp/pod-7/sock") ==
             "/run/mcp/pod-7/last_tool_call"
  end

  @tag :tmp_dir
  test "liveness_sample/1 reads the marker's mtime, and answers nil when there is none",
       %{tmp_dir: dir} do
    # Against a REAL file: the point of the signal is that it crosses a domain boundary as an mtime
    # on disk, so stubbing File.stat would test the harness instead of the crossing.
    socket = Path.join(dir, "sock")
    # `pod_dir`/`pod_id` are what the OTHER three signals read; a partial state would raise in
    # `jsonl_size/1` and the test would be measuring the fixture, not the marker.
    state = %{
      mcp_socket_path: socket,
      pod_dir: dir,
      pod_id: "pod-liveness-marker",
      session_id: "0badcafe-0000-4000-8000-000000000001"
    }

    assert {_jsonl, _cpu, _pane, nil} = Liveness.liveness_sample(state)

    marker = Fleet.Layout.pod_mcp_activity_marker(socket)
    :ok = File.touch(marker, 1_700_000_000)

    assert {_jsonl2, _cpu2, _pane2, 1_700_000_000} = Liveness.liveness_sample(state)
  end

  @tag :tmp_dir
  test "a pod with NO socket path recorded samples nil there, it does not raise", %{tmp_dir: dir} do
    assert {_j, _c, _p, nil} =
             Liveness.liveness_sample(%{
               pod_dir: dir,
               pod_id: "pod-liveness-nosocket",
               session_id: "0badcafe-0000-4000-8000-000000000001"
             })
  end
end
