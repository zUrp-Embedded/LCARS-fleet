defmodule Fleet.Spawner.Pod.LivenessTest do
  @moduledoc """
  Unobservable samples return true from liveness_moved?/2 so the deadline re-arms;
  a measurement gap must not count as inactivity.
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
    assert Liveness.liveness_moved?({10, 5}, {nil, nil})
    assert Liveness.liveness_moved?({nil, nil}, {nil, nil})
  end

  test "3-tuple probe (pane hash): a pane CHANGE alone is movement — the in-generation signal" do
    # jsonl frozen between message boundaries + holder cpu idle + TUI repainting = alive.
    assert Liveness.liveness_moved?({10, 5, 111}, {10, 5, 222})
    refute Liveness.liveness_moved?({10, 5, 111}, {10, 5, 111})
    # A nil hash on either side proves nothing (capture failure never counts as movement).
    refute Liveness.liveness_moved?({10, 5, nil}, {10, 5, 333})
    refute Liveness.liveness_moved?({10, 5, 111}, {10, 5, nil})
    assert Liveness.liveness_moved?({10, 5, 111}, {11, 5, 111})
    assert Liveness.liveness_moved?({10, 5, 111}, {nil, nil, nil})
    assert Liveness.unobservable?({nil, nil, nil})
  end

  test "unobservable?/1 flags the fully-nil sample (the tick handler logs the degrade)" do
    assert Liveness.unobservable?({nil, nil})
    refute Liveness.unobservable?({10, nil})
    refute Liveness.unobservable?({nil, 5})
    refute Liveness.unobservable?({10, 5})
  end

  test "4-tuple: the MCP marker ALONE is movement — a pod whose only sign of life is talking to us" do
    assert Liveness.liveness_moved?({10, 5, 42, 1_700_000_000}, {10, 5, 42, 1_700_000_030})
  end

  test "4-tuple: a marker that stops moving contributes NOTHING (an old call is not a live pod)" do
    # A recent but unchanged marker must not keep a pod alive indefinitely.
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

  # An upgrade or injected probe can change tuple shape between ticks.
  test "sample shapes of DIFFERENT arity are UNKNOWN, not a crash and not silence" do
    assert Liveness.liveness_moved?({10, 5, 42}, {10, 5, 42, 1_700_000_000})
    assert Liveness.liveness_moved?({10, 5, 42, 1_700_000_000}, {10, 5, 42})
    assert Liveness.liveness_moved?({10, 5}, {10, 5, 42, 1_700_000_000})
    assert Liveness.liveness_moved?(:garbage, {10, 5, 42, 1_700_000_000})
  end

  test "the marker path is derived from the SOCKET path — one name, two domains" do
    # Layout shares the filename across domains that cannot call each other.
    assert Fleet.Layout.pod_mcp_activity_marker("/run/mcp/pod-7/sock") ==
             "/run/mcp/pod-7/last_tool_call"
  end

  @tag :tmp_dir
  test "liveness_sample/1 reads the marker's mtime, and answers nil when there is none",
       %{tmp_dir: dir} do
    # Exercise the on-disk signal crossing, including File.stat, without stubbing it.
    socket = Path.join(dir, "sock")
    # Supply the state needed by the other signals so their reads cannot fail on missing fields.
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
