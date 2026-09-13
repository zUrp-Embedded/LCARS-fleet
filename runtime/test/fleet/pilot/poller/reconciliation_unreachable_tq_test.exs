defmodule Fleet.Pilot.Poller.ReconciliationUnreachableTqTest do
  use ExUnit.Case, async: false
  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.Poller.Reconciliation
  alias Fleet.Pilot.Poller.Reconciliation.Seams

  # Broker unavailability must not authorize reaping. Pair with a reachable-idle
  # case so disabling the duty entirely cannot satisfy the negative assertion.

  @repo "o/r"
  # `Fleet.PodId.parse_ref/2` exige le prefixe du depot : `o/r` -> `o-r-`.
  @pod_id "o-r-issue-7-engineer"

  defmodule KillSpy do
    def list_pods, do: [%{pod_id: "o-r-issue-7-engineer"}]
    def kill_pod(pod_id), do: Agent.update(:jg074_kills, &[pod_id | &1])
  end

  defmodule TqIdle do
    # La file REPOND : aucun work item pour ce pod. Orphelin etabli.
    def list_active, do: []
    def pod_active_issue_id(_), do: {:ok, nil}
    def pod_status(_), do: {:ok, nil}
  end

  defmodule TqUnreachable do
    # La file NE REPOND PAS — la forme exacte d'un `GenServer.call` vers un serveur mort.
    def list_active, do: []
    def pod_active_issue_id(_), do: {:ok, nil}

    def pod_status(_),
      do: exit({:timeout, {GenServer, :call, [Fleet.TaskQueue.Server, :x, 5000]}})
  end

  defmodule Forge do
    def remove_label(_r, _n, _l, _o), do: {:ok, :removed}
    def stop_stopwatch(_r, _n, _o), do: :ok
  end

  setup do
    # ExUnit supervision waits for termination before the next test reuses the global
    # name. A bare link leaves an asynchronous name-release race.
    start_supervised!(%{
      id: :jg074_kills,
      start: {Agent, :start_link, [fn -> [] end, [name: :jg074_kills]]}
    })

    :ok
  end

  defp reconcile_with(tq) do
    seams = %Seams{
      forge: Forge,
      spawner: KillSpy,
      task_queue: tq,
      repo: @repo,
      forge_opts: []
    }

    # Le suspect est deja confirme : la grace de 2 ticks est satisfaite, donc CE tick agit.
    prior = MapSet.new([{@repo, :pod, @pod_id}])
    pods = Reconciliation.snapshot_pods(KillSpy)
    _ = Reconciliation.reconcile([], [], MapSet.new(), prior, seams, pods)
    Agent.get(:jg074_kills, & &1)
  end

  test "file JOIGNABLE et pod sans tache : le reap a bien lieu (le devoir n'est pas neutralise)" do
    assert reconcile_with(TqIdle) == [@pod_id],
           "le reap nominal ne se declenche plus — le second test ne prouverait plus rien"
  end

  test "file INJOIGNABLE : aucun reap, le pod est reporte au prochain tick" do
    assert reconcile_with(TqUnreachable) == [],
           "un pod a ete reape alors que la file n'a pas repondu — " <>
             "l'indisponibilite d'un tiers est devenue un verdict sur ce pod"
  end

  # A broker failing on the first ownership read stops the whole pass, so it cannot
  # test the later reap guard. Fail only on the second read to reach that guard;
  # otherwise replacing unknown with idle there could pass unnoticed.
  describe "la garde de JG-074 couvre le transitoire qui tombe ENTRE les deux lectures" do
    defmodule TqDiesBetweenReads do
      # First status read succeeds; the second fails between ownership and reap checks.
      def list_active, do: []
      def pod_active_issue_id(_), do: {:ok, nil}

      def pod_status(_) do
        n = Agent.get_and_update(:jg074_calls, &{&1 + 1, &1 + 1})

        if n <= 1,
          do: {:ok, nil},
          else: exit({:timeout, {GenServer, :call, [Fleet.TaskQueue.Server, :x, 5000]}})
      end
    end

    setup do
      # Meme course que le `setup` du module — cf. son commentaire.
      start_supervised!(%{
        id: :jg074_calls,
        start: {Agent, :start_link, [fn -> 0 end, [name: :jg074_calls]]}
      })

      :ok
    end

    test "la file meurt entre les deux lectures : AUCUN reap" do
      assert reconcile_with(TqDiesBetweenReads) == [],
             "la file a repondu a la lecture de propriete puis est morte : le devoir de reap a " <>
               "quand meme conclu « ce pod n'a pas de tache » et l'a tue"

      # Verify both reads occurred so the intended failure window was exercised.
      assert Agent.get(:jg074_calls, & &1) >= 2,
             "la file n'a ete lue qu'une fois — le scenario « meurt entre les deux » n'a pas eu lieu"
    end
  end

  # Log attempted versus completed reap from the kill result, including exceptions.
  describe "JG-120 — la trace du reap suit l'acte au lieu de le preceder" do
    defmodule KillFails do
      def list_pods, do: [%{pod_id: "o-r-issue-7-engineer"}]
      def kill_pod(_pod_id), do: {:error, :boom}
    end

    defmodule KillRaises do
      def list_pods, do: [%{pod_id: "o-r-issue-7-engineer"}]
      def kill_pod(_pod_id), do: raise("le backend de kill est casse")
    end

    defp reap_with(spawner) do
      seams = %Seams{
        forge: Forge,
        spawner: spawner,
        task_queue: TqIdle,
        repo: @repo,
        forge_opts: []
      }

      prior = MapSet.new([{@repo, :pod, @pod_id}])
      pods = Reconciliation.snapshot_pods(spawner)

      ExUnit.CaptureLog.capture_log(fn ->
        _ = Reconciliation.reconcile([], [], MapSet.new(), prior, seams, pods)
      end)
    end

    test "un kill qui ECHOUE ne s'annonce plus comme accompli" do
      log = reap_with(KillFails)

      refute log =~ "→ REAPED",
             "la trace annonce un reap accompli alors que le kill a rendu une erreur"

      assert log =~ "did NOT land", "l'echec du kill n'apparait nulle part"
      assert log =~ "re-suspects and retries", "la trace ne dit pas que rien n'est bloque"
    end

    test "un kill qui LEVE non plus — `safe_kill/2` ne fabrique plus un `:ok`" do
      log = reap_with(KillRaises)

      refute log =~ "→ REAPED"
      assert log =~ "kill_raised", "l'exception est repliee sur un succes quelque part"
    end

    test "TEMOIN — un kill qui REUSSIT s'annonce bien, sinon le test d'a cote ne prouve rien" do
      log = reap_with(KillSpy)

      assert log =~ "→ REAPED"
      refute log =~ "did NOT land"
    end
  end

  # Unknown ownership must reach the outer fail-safe, not collapse to no refs
  # in an inner helper. Test reclamation separately from pod reaping.
  describe "JG-083 — propriete des verrous : l'indisponibilite de la file n'est pas une absence" do
    defmodule TqOwnerUnreachable do
      # Le pod POSSEDE le verrou de l'issue 7 — mais la file ne peut pas le dire.
      def list_active, do: []
      def pod_active_issue_id(_), do: {:ok, "issue-7"}

      def pod_status(_),
        do: exit({:timeout, {GenServer, :call, [Fleet.TaskQueue.Server, :x, 5000]}})
    end

    defmodule TqOwnerIdle do
      # La file REPOND : ce pod n'a pulle aucune tache. Le verrou est un vrai orphelin.
      def list_active, do: []
      def pod_active_issue_id(_), do: {:ok, nil}
      def pod_status(_), do: {:ok, nil}
    end

    defmodule ReclaimSpy do
      def remove_label(_r, n, l, _o), do: Agent.update(:jg083_reclaims, &[{n, l} | &1])
      def stop_stopwatch(_r, _n, _o), do: :ok
    end

    setup do
      # Meme course que le `setup` du module — cf. son commentaire.
      start_supervised!(%{
        id: :jg083_reclaims,
        start: {Agent, :start_link, [fn -> [] end, [name: :jg083_reclaims]]}
      })

      :ok
    end

    defp reclaims_with(tq) do
      seams = %Seams{
        forge: ReclaimSpy,
        spawner: KillSpy,
        task_queue: tq,
        repo: @repo,
        forge_opts: []
      }

      # Une issue VERROUILLEE (`lcars-in-flight`), deja suspecte au tick precedent : la grace de
      # 2 ticks est satisfaite, donc CE tick reclame — sauf si la propriete est indeterminee.
      issues = [PayloadFixture.issue(number: 7, label_names: ["lcars-in-flight"])]
      prior = MapSet.new([{@repo, :issue, 7}])
      pods = Reconciliation.snapshot_pods(KillSpy)
      _ = Reconciliation.reconcile(issues, [], MapSet.new(), prior, seams, pods)
      Agent.get(:jg083_reclaims, & &1)
    end

    test "TEMOIN — file JOIGNABLE et pod sans tache pullee : le verrou est bien reclame" do
      assert reclaims_with(TqOwnerIdle) != [],
             "le reclaim nominal ne se declenche plus — le second test ne prouverait plus rien"
    end

    test "file INJOIGNABLE : AUCUN reclaim, le verrou du pod vivant est preserve" do
      assert reclaims_with(TqOwnerUnreachable) == [],
             "le verrou d'un pod vivant a ete reclame parce que la file n'a pas repondu — " <>
               "l'indisponibilite d'un tiers est devenue un verdict de propriete"
    end
  end
end
