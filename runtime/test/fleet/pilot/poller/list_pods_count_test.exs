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
    # Take one snapshot explicitly, then prove reconciliation does not enumerate again.
    # This observes the callee's reuse, not Poller's complete multi-repo loop.
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
