defmodule Fleet.Spawner.PodWardenTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.PodWarden, as: R

  defp s(list), do: MapSet.new(list)

  test "orphelin vu 1ʳᵉ fois → PAS reapé (grace), devient suspect" do
    # sock "p1" sans pod vivant ; aucun suspect précédent → on n'agit pas, on note.
    {to_reap, suspects} = R.reconcile_decision(s([]), s(["p1"]), s([]))
    assert MapSet.equal?(to_reap, s([]))
    assert MapSet.equal?(suspects, s(["p1"]))
  end

  test "orphelin vu 2 ticks de suite (déjà suspect) → REAPÉ" do
    {to_reap, suspects} = R.reconcile_decision(s([]), s(["p1"]), s(["p1"]))
    assert MapSet.equal?(to_reap, s(["p1"]))
    # reapé → plus suspect.
    assert MapSet.equal?(suspects, s([]))
  end

  test "pod vivant (registry) → jamais orphelin ni suspect" do
    {to_reap, suspects} = R.reconcile_decision(s(["p1"]), s(["p1"]), s([]))
    assert MapSet.equal?(to_reap, s([]))
    assert MapSet.equal?(suspects, s([]))
  end

  test "suspect redevenu vivant (re-registré entre 2 ticks) → PAS reapé (race spawn évitée)" do
    # p1 était suspect, mais il est maintenant dans le registry (live) ET a une sock → pas un orphelin.
    {to_reap, suspects} = R.reconcile_decision(s(["p1"]), s(["p1"]), s(["p1"]))
    assert MapSet.equal?(to_reap, s([]))
    assert MapSet.equal?(suspects, s([]))
  end

  test "mélange : un confirmé reapé, un nouveau en grace, un vivant ignoré" do
    live = s(["alive"])
    socks = s(["alive", "old-orphan", "new-orphan"])
    prev = s(["old-orphan"])
    {to_reap, suspects} = R.reconcile_decision(live, socks, prev)
    assert MapSet.equal?(to_reap, s(["old-orphan"]))
    assert MapSet.equal?(suspects, s(["new-orphan"]))
  end

  # GC des pod_dirs : décision PURE (terminale + orpheline + grace 2-tick).
  defp tomb(pod_id, phase),
    do: %{pod_id: pod_id, phase: phase, state_dir: "/s/#{pod_id}", pod_dir: "/p/pod_#{pod_id}"}

  describe "reconcile_pod_dir_gc/3" do
    test "tombstone terminale + orpheline vue 1ʳᵉ fois → PAS GC (grace), devient suspect" do
      {to_gc, suspects} = R.reconcile_pod_dir_gc([tomb("p1", "succeeded")], s([]), s([]))
      assert to_gc == []
      assert MapSet.equal?(suspects, s(["p1"]))
    end

    test "tombstone terminale + orpheline vue 2 ticks (déjà suspecte) → GC" do
      {to_gc, suspects} = R.reconcile_pod_dir_gc([tomb("p1", "succeeded")], s([]), s(["p1"]))
      assert [%{pod_id: "p1", pod_dir: "/p/pod_p1", state_dir: "/s/p1"}] = to_gc
      assert MapSet.equal?(suspects, s([]))
    end

    test "toutes les phases terminales (released, killed) sont candidates" do
      for phase <- ["released", "killed"] do
        {to_gc, _} = R.reconcile_pod_dir_gc([tomb("p1", phase)], s([]), s(["p1"]))
        assert [%{pod_id: "p1"}] = to_gc
      end
    end

    test "tombstone terminale mais VIVANTE (pod_id dans live) → jamais GC ni suspecte" do
      {to_gc, suspects} = R.reconcile_pod_dir_gc([tomb("p1", "succeeded")], s(["p1"]), s(["p1"]))
      assert to_gc == []
      assert MapSet.equal?(suspects, s([]))
    end

    test "tombstone NON-terminale (:monitoring) orpheline → épargnée (recovery intacte)" do
      {to_gc, suspects} = R.reconcile_pod_dir_gc([tomb("p1", "monitoring")], s([]), s(["p1"]))
      assert to_gc == []
      assert MapSet.equal?(suspects, s([]))
    end

    test "mélange : terminale-orpheline confirmée GC, terminale-orpheline neuve en grace, vivante et non-terminale épargnées" do
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
