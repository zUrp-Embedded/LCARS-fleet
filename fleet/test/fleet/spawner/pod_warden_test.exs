defmodule Fleet.Spawner.PodWardenTest do
  # ⚠ `async: false` : ce fichier ECRIT `:spawner_tmux_sock_base` en env d'APPLICATION, qui est
  # globale au node. Pendant la fenetre — restauration `on_exit` comprise — tout test concurrent qui
  # lit cette cle lit la valeur de celui-ci. Mesure du 2026-08-17 : la meme forme a tue
  # `Pilot.ApplicationTest` sur une racine de catalogue temporaire qui ne lui appartenait pas, dans
  # le build d'image et pas sur la machine de dev — la collision depend du nombre de coeurs et de
  # l'ordre du seed, donc elle mord la ou ca coute le plus cher.
  use ExUnit.Case, async: false

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

  # JG-035 — LA JUMELLE DISAIT, CELLE-CI SE TAISAIT. `live_pod_ids/0` rend `:unavailable` sur
  # exception et le tick entier est saute avec un warning motive ; `sock_pod_ids/0` rendait un
  # MapSet VIDE sur tout echec de `File.ls`, donc `difference(socks, live)` etait vide, donc
  # « aucun orphelin » — fail-safe (rien n'est tue a tort) et INDISCERNABLE du tick nominal. La
  # branche voisine avait ete ecrite precisement pour rendre cette distinction visible.
  #
  # L'issue de reclaim est inchangee : aucun orphelin declare dans les deux cas. Ce qui change est
  # que l'operateur voit POURQUOI il ne s'est rien passe.
  describe "JG-035 — une base de sockets illisible n'est pas une base vide" do
    @tag :tmp_dir
    test "base ILLISIBLE → tick saute, horloges de grace gelees", %{tmp_dir: tmp} do
      base = Path.join(tmp, "socks")
      File.mkdir_p!(base)
      File.chmod!(base, 0o000)
      on_exit(fn -> File.chmod(base, 0o755) end)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_tmux_sock_base, base)

      state = %{suspects: s(["p1"]), gc_suspects: s([])}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, ^state} = R.handle_info(:reap_tick, state)
        end)

      # Sous un uid qui ignore les permissions (root), la base reste listable : le cas ne se joue
      # pas. La suite tourne en `builder` en CI.
      case File.ls(base) do
        {:error, _} -> assert log =~ "socket base unavailable"
        {:ok, _} -> :ok
      end
    end

    @tag :tmp_dir
    test "TEMOIN — base LISIBLE et vide → le tick se deroule, aucun message d'indisponibilite", %{
      tmp_dir: tmp
    } do
      base = Path.join(tmp, "socks")
      File.mkdir_p!(base)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_tmux_sock_base, base)

      state = %{suspects: s([]), gc_suspects: s([])}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, _} = R.handle_info(:reap_tick, state)
        end)

      refute log =~ "socket base unavailable"
    end
  end
end
