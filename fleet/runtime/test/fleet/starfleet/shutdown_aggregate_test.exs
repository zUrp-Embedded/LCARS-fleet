defmodule Fleet.Starfleet.Shutdown.AggregateDispatcherTest do
  @moduledoc """
  REAL backend of the `:shutdown_dispatcher` seam. async: false: `refuse_new_jobs` mutates the global
  `Fleet.Shutdown.Quiesce` flag (on_exit `resume!` mandatory).

  CI-02: the drain count is now `TaskQueue.list_active/0` (queued + worked work-items — residents with
  NO active work-item are inherently excluded) + the completion offloads (seam `:completion_inflight_fun`),
  NOT a live-pod scan. Fail-closed on the broker (present-but-unreachable → sentinel > 0), honest 0 on a
  dead completion supervisor (its Tasks are already dead).
  """
  use ExUnit.Case, async: false

  alias Fleet.Shutdown.Quiesce
  alias Fleet.Starfleet.Shutdown.AggregateDispatcher

  # Broker stubs injected via `:fleet_starfleet, :task_queue_mod`. The REAL broker IS present in the test
  # env (so `task_queue_running?` is true) — these induce specific `list_active` returns/failures.
  defmodule TwoActiveBroker do
    def list_active, do: [%{id: "a"}, %{id: "b"}]
  end

  defmodule EmptyBroker do
    def list_active, do: []
  end

  defmodule RaisingBroker do
    def list_active, do: raise("broker unreachable (test)")
  end

  defmodule ExitingBroker do
    def list_active, do: exit(:noproc)
  end

  setup do
    on_exit(&Quiesce.resume!/0)
    :ok
  end

  defp inject_broker(mod),
    do: Fleet.Starfleet.TestEnv.put_env_restoring(:fleet_starfleet, :task_queue_mod, mod)

  defp inject_completion(fun),
    do: Fleet.Starfleet.TestEnv.put_env_restoring(:fleet_starfleet, :completion_inflight_fun, fun)

  test "refuse_new_jobs/1 activates quiescence" do
    Quiesce.resume!()
    refute Quiesce.quiescing?()
    assert :ok = AggregateDispatcher.refuse_new_jobs(reason: :shutdown)
    assert Quiesce.quiescing?()
  end

  test "in_flight_count/0 = active work-items + completion offloads (work-items, NEVER a pod scan → residents excluded)" do
    # The count is the broker's ACTIVE work-items, not live pods: a resident arch/pipe-eng (no active
    # work-item) is inherently absent — the CI-02 fix for "one open project ⇒ in_flight > 0 forever".
    inject_broker(TwoActiveBroker)
    inject_completion(fn -> 3 end)
    assert AggregateDispatcher.in_flight_count() == 5
  end

  test "list_active that RAISES → in_flight_count > 0 (fail-closed: broker present but unreachable)" do
    inject_broker(RaisingBroker)
    inject_completion(fn -> 0 end)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "list_active that EXITs (:noproc) → in_flight_count > 0 (no undercount)" do
    inject_broker(ExitingBroker)
    inject_completion(fn -> 0 end)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "completion count 0 (supervisor genuinely absent) → contributes an honest 0" do
    # The kept asymmetry: a DOWN completion supervisor ⇒ its Tasks are dead with it ⇒ honest 0 (the seam
    # returns 0), so step-off does not make every stop time out.
    inject_broker(EmptyBroker)
    inject_completion(fn -> 0 end)
    assert AggregateDispatcher.in_flight_count() == 0
  end

  test "completion count that RAISES → in_flight_count > 0 (fail-closed: present-but-uncountable, not a fake 0)" do
    # A RAISING count is NOT a dead supervisor: the Tasks may be alive (completions mid-push) and we just
    # could not count them → fail-closed, never a fake 0 that would cut a live completion.
    inject_broker(EmptyBroker)
    inject_completion(fn -> raise "count boom" end)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "completion count :unknown (supervisor present but uncountable) → in_flight_count > 0 (fail-closed)" do
    inject_broker(EmptyBroker)
    inject_completion(fn -> :unknown end)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "drain with a RAISING broker → does NOT conclude :drained (fail-closed sentinel → timeout)" do
    inject_broker(RaisingBroker)
    inject_completion(fn -> 0 end)
    name = :"sd_ci02_#{System.unique_integer([:positive])}"

    {:ok, _} =
      start_supervised(
        {Fleet.Starfleet.Shutdown, name: name, dispatcher: AggregateDispatcher, poll_ms: 10}
      )

    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 200)
    assert %{status: :timeout} = :sys.get_state(name)
  end
end
