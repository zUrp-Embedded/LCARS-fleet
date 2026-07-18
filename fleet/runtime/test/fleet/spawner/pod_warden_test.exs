defmodule Fleet.Spawner.PodWardenTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PodWarden, as: R

  defp s(list), do: MapSet.new(list)

  test "orphan seen for the 1st time → NOT reaped (grace), becomes suspect" do
    # sock "p1" without a live pod; no previous suspect → do not act, take note.
    {to_reap, suspects} = R.reconcile_decision(s([]), s(["p1"]), s([]))
    assert MapSet.equal?(to_reap, s([]))
    assert MapSet.equal?(suspects, s(["p1"]))
  end

  test "orphan seen 2 ticks in a row (already suspect) → REAPED" do
    {to_reap, suspects} = R.reconcile_decision(s([]), s(["p1"]), s(["p1"]))
    assert MapSet.equal?(to_reap, s(["p1"]))
    # reaped → no longer suspect.
    assert MapSet.equal?(suspects, s([]))
  end

  test "live pod (registry) → never orphan nor suspect" do
    {to_reap, suspects} = R.reconcile_decision(s(["p1"]), s(["p1"]), s([]))
    assert MapSet.equal?(to_reap, s([]))
    assert MapSet.equal?(suspects, s([]))
  end

  test "suspect back alive (re-registered between 2 ticks) → NOT reaped (spawn race avoided)" do
    # p1 was suspect, but it is now in the registry (live) AND has a sock → not an orphan.
    {to_reap, suspects} = R.reconcile_decision(s(["p1"]), s(["p1"]), s(["p1"]))
    assert MapSet.equal?(to_reap, s([]))
    assert MapSet.equal?(suspects, s([]))
  end

  test "mix: a confirmed one reaped, a new one in grace, a live one ignored" do
    live = s(["alive"])
    socks = s(["alive", "old-orphan", "new-orphan"])
    prev = s(["old-orphan"])
    {to_reap, suspects} = R.reconcile_decision(live, socks, prev)
    assert MapSet.equal?(to_reap, s(["old-orphan"]))
    assert MapSet.equal?(suspects, s(["new-orphan"]))
  end

  # pod_dir GC: PURE decision (terminal + orphan + 2-tick grace).
  defp tomb(pod_id, phase),
    do: %{pod_id: pod_id, phase: phase, state_dir: "/s/#{pod_id}", pod_dir: "/p/pod_#{pod_id}"}

  describe "reconcile_pod_dir_gc/3" do
    test "terminal + orphan tombstone seen for the 1st time → NOT GC'd (grace), becomes suspect" do
      {to_gc, suspects} = R.reconcile_pod_dir_gc([tomb("p1", "succeeded")], s([]), s([]))
      assert to_gc == []
      assert MapSet.equal?(suspects, s(["p1"]))
    end

    test "terminal + orphan tombstone seen 2 ticks (already suspect) → GC" do
      {to_gc, suspects} = R.reconcile_pod_dir_gc([tomb("p1", "succeeded")], s([]), s(["p1"]))
      assert [%{pod_id: "p1", pod_dir: "/p/pod_p1", state_dir: "/s/p1"}] = to_gc
      assert MapSet.equal?(suspects, s([]))
    end

    test "all terminal phases (released, killed) are candidates" do
      for phase <- ["released", "killed"] do
        {to_gc, _} = R.reconcile_pod_dir_gc([tomb("p1", phase)], s([]), s(["p1"]))
        assert [%{pod_id: "p1"}] = to_gc
      end
    end

    test "terminal but LIVE tombstone (pod_id in live) → never GC'd nor suspect" do
      {to_gc, suspects} = R.reconcile_pod_dir_gc([tomb("p1", "succeeded")], s(["p1"]), s(["p1"]))
      assert to_gc == []
      assert MapSet.equal?(suspects, s([]))
    end

    test "NON-terminal (:monitoring) orphan tombstone → spared (recovery intact)" do
      {to_gc, suspects} = R.reconcile_pod_dir_gc([tomb("p1", "monitoring")], s([]), s(["p1"]))
      assert to_gc == []
      assert MapSet.equal?(suspects, s([]))
    end

    test "mix: confirmed terminal-orphan GC'd, fresh terminal-orphan in grace, live and non-terminal spared" do
      tombstones = [
        tomb("old-done", "succeeded"),
        tomb("new-done", "succeeded"),
        tomb("alive", "succeeded"),
        tomb("inflight", "monitoring")
      ]

      {to_gc, suspects} =
        R.reconcile_pod_dir_gc(tombstones, s(["alive"]), s(["old-done"]))

      assert [%{pod_id: "old-done"}] = to_gc
      assert MapSet.equal?(suspects, s(["new-done"]))
    end
  end
end
