defmodule ReconciliationUnreachableTqTest do
  use ExUnit.Case, async: false
  alias Fleet.Pilot.Poller.Reconciliation
  alias Fleet.Pilot.Poller.Reconciliation.Seams

  # JG-074 — la file de taches est un POINT DE SERIALISATION PARTAGE : `pod_status/1` est un
  # `GenServer.call` sans timeout explicite (donc 5 s) vers un serveur unique que tous les pods
  # interrogent. Un redemarrage par son superviseur, ou une pointe de charge, et l'appel `exit`.
  #
  # Avant le fix, ce silence devenait `false` — indistinguable de « ce pod n'a pas de tache » — et
  # le pod partait au reap. Un pod peut-etre EN TRAIN DE TRAVAILLER, tue pour l'indisponibilite
  # d'un autre.
  #
  # Les deux tests vont par paire et le premier est le garde-fou du second : sans lui, faire
  # disparaitre le reap suffirait a rendre le second vert.

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
    def pod_status(_), do: exit({:timeout, {GenServer, :call, [Fleet.TaskQueue.Server, :x, 5000]}})
  end

  defmodule Forge do
    def remove_label(_r, _n, _l, _o), do: {:ok, :removed}
    def stop_stopwatch(_r, _n, _o), do: :ok
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: :jg074_kills)
    on_exit(fn -> if Process.whereis(:jg074_kills), do: Agent.stop(:jg074_kills) end)
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
end
