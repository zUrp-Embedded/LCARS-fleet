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
end
