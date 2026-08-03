defmodule ListPodsCountTest do
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

  test "UN SEUL list_pods par passe, quel que soit le nombre de verrous candidats" do
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

    _ = Reconciliation.reconcile(issues, [], MapSet.new(), prior, seams)

    calls = Agent.get(:lp_counter, & &1)
    Agent.stop(:lp_counter)

    # Avant : 2 + N (deux duties + un par verrou candidat) => 7 ici. Apres : 1.
    assert calls == 1, "list_pods appele #{calls} fois pour 5 verrous — le snapshot ne tient pas"
  end
end
