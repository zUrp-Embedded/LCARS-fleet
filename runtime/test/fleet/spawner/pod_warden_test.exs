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

  # Le warden observe par ses coutures : `reap_fun` et `gc_fun` rapportent au test, les sources
  # sont celles que le temoin passe. `opts` gagne sur les defauts.
  defp start_warden(opts) do
    parent = self()

    defaults = [
      name: nil,
      interval_ms: 10,
      live_fun: fn -> {:ok, s([])} end,
      socks_fun: fn -> {:ok, s([])} end,
      reap_fun: fn pod_id -> send(parent, {:reaped, pod_id}) end,
      gc_fun: fn _live, prev -> prev end
    ]

    start_supervised!({R, Keyword.merge(defaults, opts)})
  end

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

      # `init/1` pose les VRAIES sources (c'est le vrai `sock_pod_ids/0` qu'on veut voir refuser
      # la base) ; le tick est joue depuis ce processus, et le timer qu'`init` arme atterrit dans
      # la boite du test, ignore.
      {:ok, state} = R.init([])
      state = %{state | suspects: s(["p1"])}

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

      {:ok, state} = R.init([])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, _} = R.handle_info(:reap_tick, state)
        end)

      refute log =~ "socket base unavailable"
    end
  end

  # ─── LE TICK, SUR `Fleet.PeriodicCheck` ─────────────────────────────────────────────────────
  #
  # Les temoins du haut n'exercent que les decisions pures ; ceux-ci demarrent le GenServer et
  # observent le tick par ses coutures, sans disque ni Registry : la branche nominale, le gel sur
  # une source indisponible, le filet sur une source qui leve, et le rejeu synchrone.
  describe "le tick, sur PeriodicCheck" do
    test "orphelin confirme au 2e tick → reap ; le pod vivant, jamais" do
      start_warden(
        live_fun: fn -> {:ok, s(["p-live"])} end,
        socks_fun: fn -> {:ok, s(["p-live", "p-ghost"])} end
      )

      assert_receive {:reaped, "p-ghost"}, 1_000
      refute_received {:reaped, "p-live"}
    end

    test "source INDISPONIBLE → la grace GELE : le suspect n'est ni oublie ni traite" do
      parent = self()
      counter = :counters.new(1, [])

      # tick 1 : orphelin vu, suspect. tick 2 : base illisible, gel. tick 3 : revu → confirme.
      # Sans gel, le tick 2 lirait « aucun orphelin », le suspect tomberait, et le reap ne
      # viendrait qu'au tick 4. Le reap rapporte le numero du tick qui l'a decide.
      start_warden(
        socks_fun: fn ->
          :counters.add(counter, 1, 1)
          if :counters.get(counter, 1) == 2, do: :unavailable, else: {:ok, s(["p-ghost"])}
        end,
        reap_fun: fn pod_id -> send(parent, {:reaped, pod_id, :counters.get(counter, 1)}) end
      )

      assert_receive {:reaped, "p-ghost", 3}, 1_000
    end

    test "source qui LEVE → rien n'est reap et le warden SURVIT (le filet de PeriodicCheck)" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          warden =
            start_warden(
              live_fun: fn -> raise "registry gone" end,
              socks_fun: fn -> {:ok, s(["p-ghost"])} end
            )

          refute_receive {:reaped, _}, 100
          assert Process.alive?(warden)
        end)

      assert log =~ "RAISED"
    end

    test "check_now rejoue le tick de maniere synchrone et rend les suspects" do
      warden = start_warden(interval_ms: 3_600_000, socks_fun: fn -> {:ok, s(["p-ghost"])} end)

      assert {:ok, %{suspects: suspects}} = R.check_now(warden)
      assert MapSet.equal?(suspects, s(["p-ghost"]))
      refute_received {:reaped, _}

      # Second rejeu : le suspect est confirme, reap, et sort des suspects.
      assert {:ok, %{suspects: suspects}} = R.check_now(warden)
      assert_received {:reaped, "p-ghost"}
      assert MapSet.size(suspects) == 0
    end
  end
end
