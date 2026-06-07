defmodule Fleet.Spawner.PodKickTest do
  @moduledoc """
  R3b / F-C4b-2 — kick AUTONOME readiness-gated. La boucle `{:kick_attempt, n}`
  remplace le yop à délai fixe (perdu si le REPL n'est pas prêt, observé C4b live).

  Ce test verrouille la mécanique BORNÉE/NO-OP (le `handle_info` est appelé
  directement → `send_after` cible le process de test, observable). Le chemin
  `tmux joignable → yop → stop dès pull` exige un vrai serveur tmux → prouvé LIVE
  (PASSE 5/6), pas ici.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod

  setup do
    Application.put_env(:fleet_spawner, :kick_retry_ms, 10)
    Application.put_env(:fleet_spawner, :kick_max_attempts, 3)
    # Les fake_pods n'ont aucun mandat → chemin BOOTSTRAP (cap/retry dédiés). On les override
    # aussi pour garder les tests rapides + bornés.
    Application.put_env(:fleet_spawner, :kick_bootstrap_retry_ms, 10)
    Application.put_env(:fleet_spawner, :kick_bootstrap_max, 3)

    on_exit(fn ->
      Application.delete_env(:fleet_spawner, :kick_retry_ms)
      Application.delete_env(:fleet_spawner, :kick_max_attempts)
      Application.delete_env(:fleet_spawner, :kick_bootstrap_retry_ms)
      Application.delete_env(:fleet_spawner, :kick_bootstrap_max)
    end)

    :ok
  end

  defp fake_pod, do: "no-such-pod-#{System.unique_integer([:positive])}"

  test "pas de tmux_session → no-op, aucun re-kick planifié" do
    assert {:noreply, _} =
             Pod.handle_info({:kick_attempt, 1}, %{tmux_session: nil, pod_id: fake_pod()})

    refute_receive {:kick_attempt, _}, 60
  end

  test "tmux pas encore up (serveur absent) + mandat non pull → retente (reschedule n+1)" do
    state = %{tmux_session: "sess", pod_id: fake_pod()}
    assert {:noreply, _} = Pod.handle_info({:kick_attempt, 1}, state)
    # `alive?` faux (pas de vrai serveur) → branche reschedule, pas yop perdu.
    assert_receive {:kick_attempt, 2}, 300
  end

  test "cap atteint (n >= max) → abandon, aucun re-kick" do
    state = %{tmux_session: "sess", pod_id: fake_pod()}
    assert {:noreply, _} = Pod.handle_info({:kick_attempt, 3}, state)
    refute_receive {:kick_attempt, _}, 60
  end

  test "mandat déjà pull (task :assigned) → stop, aucun re-kick" do
    pod = fake_pod()
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})
    # get_for_pod = ce que fait le pod via MCP get_task → la task passe :pending → :assigned
    {:ok, _} = Fleet.TaskQueue.get_for_pod(pod)
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    assert {:noreply, _} =
             Pod.handle_info({:kick_attempt, 1}, %{tmux_session: "sess", pod_id: pod})

    refute_receive {:kick_attempt, _}, 60
  end

  test "pod SANS mandat → mode bootstrap : stop au cap bootstrap, pas au cap worker" do
    # cap bootstrap (2) < cap worker (9). fake_pod = aucune task → no_pending_mandate? = true.
    Application.put_env(:fleet_spawner, :kick_bootstrap_max, 2)
    Application.put_env(:fleet_spawner, :kick_max_attempts, 9)

    state = %{tmux_session: "sess", pod_id: fake_pod()}

    # n=2 ≥ cap bootstrap (2) → stop. Si le cap worker (9) s'appliquait, n=2 < 9 → reschedule.
    assert {:noreply, _} = Pod.handle_info({:kick_attempt, 2}, state)
    refute_receive {:kick_attempt, _}, 80
  end

  test "pod AVEC mandat pending → mode worker : continue au-delà du cap bootstrap" do
    Application.put_env(:fleet_spawner, :kick_bootstrap_max, 2)
    Application.put_env(:fleet_spawner, :kick_max_attempts, 9)

    pod = fake_pod()

    # enqueue SANS get_for_pod → task `:pending` (pas pull) → no_pending_mandate? = false (worker).
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    state = %{tmux_session: "sess", pod_id: pod}
    # n=3 > cap bootstrap (2) MAIS < cap worker (9) → reschedule (chemin worker, tmux pas up).
    assert {:noreply, _} = Pod.handle_info({:kick_attempt, 3}, state)
    assert_receive {:kick_attempt, 4}, 300
  end
end
