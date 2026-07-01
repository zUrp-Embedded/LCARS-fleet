defmodule Fleet.Spawner.PodKickTest do
  @moduledoc """
  R3b / F-C4b-2 — kick AUTONOME readiness-gated. La boucle remplace le yop à délai
  fixe (perdu si le REPL n'est pas prêt, observé C4b live).

  Depuis la migration `Pod` → `gen_statem`, le kick est un **generic timeout nommé
  `:kick`** : l'event est `{:timeout, :kick}` de contenu `{:attempt, n}`, et le handler
  est `Pod.handle_event/4` (pas `handle_info/2`). On l'appelle directement et on assert
  sur les ACTIONS de timer RETOURNÉES (au lieu de l'ancien `send_after`→mailbox observé
  par `assert_receive`, qui n'existe plus avec un timer natif) :
    - reschedule = action `{{:timeout, :kick}, retry, {:attempt, n+1}}` ;
    - stop (ACK / cap) = action d'annulation `{{:timeout, :kick}, :infinity, _}` ;
    - no-op (pas de tmux) = `:keep_state_and_data` sans action.
  Le chemin `tmux joignable → yop → stop dès pull` exige un vrai serveur tmux → prouvé
  LIVE (PASSE 5/6), pas ici.
  """
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod

  # Le kick est insensible à l'état (il matche sur `data.tmux_session`) : on passe un nom
  # d'état quelconque (:monitoring) en 3ᵉ argument de handle_event/4.
  @state :monitoring

  setup do
    Application.put_env(:fleet_spawner, :kick_retry_ms, 10)
    Application.put_env(:fleet_spawner, :kick_max_attempts, 3)
    # Les fake_pods n'ont aucun brief → chemin BOOTSTRAP (cap/retry dédiés). On les override
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
    # Pas de tmux → no-op pur : aucune action de timer (ni reschedule, ni cancel).
    assert :keep_state_and_data =
             Pod.handle_event(
               {:timeout, :kick},
               {:attempt, 1},
               @state,
               %{tmux_session: nil, pod_id: fake_pod()}
             )
  end

  test "tmux pas encore up (serveur absent) + brief non pull → retente (reschedule n+1)" do
    data = %{tmux_session: "sess", pod_id: fake_pod()}

    # `alive?` faux (pas de vrai serveur) → branche reschedule (action attempt n+1), pas yop perdu.
    assert {:keep_state_and_data, [{{:timeout, :kick}, _retry, {:attempt, 2}}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 1}, @state, data)
  end

  test "cap atteint (n >= max) → abandon (cancel), aucun reschedule" do
    data = %{tmux_session: "sess", pod_id: fake_pod()}

    # cap (3) atteint → action d'ANNULATION du generic timeout :kick (:infinity), pas de reschedule.
    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 3}, @state, data)
  end

  test "brief déjà pull (task :assigned) → stop (cancel), aucun reschedule" do
    pod = fake_pod()
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})
    # get_for_pod = ce que fait le pod via MCP get_task → la task passe :pending → :assigned
    {:ok, _} = Fleet.TaskQueue.get_for_pod(pod)
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 1}, @state, %{
               tmux_session: "sess",
               pod_id: pod
             })
  end

  test "pod SANS brief → mode bootstrap : stop au cap bootstrap, pas au cap worker" do
    # cap bootstrap (2) < cap worker (9). fake_pod = aucune task → no_pending_brief? = true.
    Application.put_env(:fleet_spawner, :kick_bootstrap_max, 2)
    Application.put_env(:fleet_spawner, :kick_max_attempts, 9)

    data = %{tmux_session: "sess", pod_id: fake_pod()}

    # n=2 ≥ cap bootstrap (2) → stop (cancel). Si le cap worker (9) s'appliquait, n=2 < 9 → reschedule.
    assert {:keep_state_and_data, [{{:timeout, :kick}, :infinity, _}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 2}, @state, data)
  end

  test "pod AVEC brief pending → mode worker : continue au-delà du cap bootstrap" do
    Application.put_env(:fleet_spawner, :kick_bootstrap_max, 2)
    Application.put_env(:fleet_spawner, :kick_max_attempts, 9)

    pod = fake_pod()

    # enqueue SANS get_for_pod → task `:pending` (pas pull) → no_pending_brief? = false (worker).
    {:ok, _} = Fleet.TaskQueue.enqueue(pod, %{brief: "x"})
    on_exit(fn -> Fleet.TaskQueue.clear_for_pod(pod) end)

    data = %{tmux_session: "sess", pod_id: pod}
    # n=3 > cap bootstrap (2) MAIS < cap worker (9) → reschedule (chemin worker, tmux pas up).
    assert {:keep_state_and_data, [{{:timeout, :kick}, _retry, {:attempt, 4}}]} =
             Pod.handle_event({:timeout, :kick}, {:attempt, 3}, @state, data)
  end
end
