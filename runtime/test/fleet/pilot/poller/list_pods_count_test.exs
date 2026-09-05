defmodule Fleet.Pilot.Poller.ListPodsCountTest do
  use ExUnit.Case, async: false
  alias Fleet.Pilot.Poller.Reconciliation
  alias Fleet.Pilot.Poller.Reconciliation.Seams

  defmodule CountingSpawner do
    def list_pods do
      Agent.update(:lp_counter, &(&1 + 1))
      []
    end
  end

  defmodule TQ do
    def list_active, do: []
    def pod_active_issue_id(_), do: {:ok, nil}
    def pod_status(_), do: {:ok, nil}
  end

  defmodule Forge do
    def remove_label(_r, _n, _l, _o), do: {:ok, :removed}
    def stop_stopwatch(_r, _n, _o), do: :ok
  end

  test "ZERO list_pods dans reconcile — la photo est prise par le TICK, pas par la passe" do
    # La propriete a CHANGE DE NATURE et elle est plus forte qu'avant. Premiere version :
    # « un seul appel par passe » (contre 2 + N avant, mesure : 6 pour 5 verrous). Maintenant la
    # photo remonte au TICK (BL-6-40, contexte de tick), donc `reconcile` n'en prend AUCUNE — sur
    # R repos, c'est 1 appel au lieu de R.
    #
    # Le compteur reste le meme instrument : il prouve que la lecture n'est pas revenue se cacher
    # dans le callee. Un `list_pods` qui reapparaitrait ici annulerait le gain sans qu'aucun test
    # de comportement ne le voie — les resultats seraient identiques, seul le nombre d'appels
    # changerait.
    {:ok, _} = Agent.start_link(fn -> 0 end, name: :lp_counter)

    lock = %{"name" => Fleet.Labels.in_flight()}
    issues = for n <- 1..5, do: %{"number" => n, "labels" => [lock]}
    prior = MapSet.new(for n <- 1..5, do: {"o/r", :issue, n})

    seams = %Seams{
      forge: Forge,
      spawner: CountingSpawner,
      task_queue: TQ,
      repo: "o/r",
      forge_opts: []
    }

    # Le tick prend la photo UNE fois (ici, a la main : c'est ce que fait `do_poll`).
    pods = Reconciliation.snapshot_pods(CountingSpawner)
    assert Agent.get(:lp_counter, & &1) == 1, "la photo du tick doit couter exactement un appel"

    _ = Reconciliation.reconcile(issues, [], MapSet.new(), prior, seams, pods)

    calls = Agent.get(:lp_counter, & &1)
    Agent.stop(:lp_counter)

    assert calls == 1,
           "reconcile a rappele list_pods (#{calls} au total) — la lecture est revenue dans le callee"
  end
end
