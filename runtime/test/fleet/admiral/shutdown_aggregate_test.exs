defmodule Fleet.Admiral.Shutdown.AggregateDispatcherTest do
  @moduledoc """
  Checks aggregate count contributions with broker/completion stubs and real shared
  quiescence accounting. The real broker remains present for the presence gate.
  Stub failures do not establish actual supervisor death or work completion.
  """
  use ExUnit.Case, async: false
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Admiral.Shutdown.AggregateDispatcher
  alias Fleet.Shutdown.Quiesce

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
    do: Fleet.TestEnv.put_env_restoring(:lcars_fleet, :admiral_task_queue_mod, mod)

  defp inject_completion(fun),
    do: Fleet.TestEnv.put_env_restoring(:lcars_fleet, :admiral_completion_inflight_fun, fun)

  # Subtract adjacent busy_count observations to isolate injected contributions.
  # A killed busy holder can leave a permanent count; these separate reads remain racy.
  defp controlled_in_flight do
    total = AggregateDispatcher.in_flight_count()
    total - Quiesce.busy_count()
  end

  test "refuse_new_jobs/1 activates quiescence" do
    Quiesce.resume!()
    refute Quiesce.quiescing?()
    assert :ok = AggregateDispatcher.refuse_new_jobs(reason: :shutdown)
    assert Quiesce.quiescing?()
  end

  test "in_flight_count/0 = active work-items + completion offloads (work-items, NEVER a pod scan → residents excluded)" do
    inject_broker(TwoActiveBroker)
    inject_completion(fn -> 3 end)
    assert controlled_in_flight() == 5
  end

  test "in_flight_count/0 also sums the synchronous finalizers inside Quiesce.busy/1" do
    # Synchronous finalizers can exist outside broker/offload counts.
    inject_broker(EmptyBroker)
    inject_completion(fn -> 0 end)

    base = AggregateDispatcher.in_flight_count()

    Quiesce.busy(fn ->
      assert AggregateDispatcher.in_flight_count() == base + 1
    end)

    assert AggregateDispatcher.in_flight_count() == base
    assert controlled_in_flight() == 0
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
    # This injects zero; it does not stop a completion supervisor.
    inject_broker(EmptyBroker)
    inject_completion(fn -> 0 end)
    assert controlled_in_flight() == 0
  end

  test "completion count that RAISES → in_flight_count > 0 (fail-closed: present-but-uncountable, not a fake 0)" do
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
        {Fleet.Admiral.Shutdown, name: name, dispatcher: AggregateDispatcher, poll_ms: 10}
      )

    assert :ok = Fleet.Admiral.Shutdown.drain_in_flight(name: name, grace_ms: 200)
    assert %{status: :timeout} = settle(name)
  end
end
