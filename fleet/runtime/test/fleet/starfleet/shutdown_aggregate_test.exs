defmodule Fleet.Starfleet.Shutdown.AggregateDispatcherTest do
  @moduledoc """
  REAL backend of the `:shutdown_dispatcher` seam (R4 D5 brick 2/3). async: false:
  `refuse_new_jobs` mutates the global `Fleet.Shutdown.Quiesce` flag — on_exit
  resume! is mandatory.
  """
  use ExUnit.Case, async: false

  alias Fleet.Shutdown.Quiesce
  alias Fleet.Starfleet.Shutdown.AggregateDispatcher

  # Stubs injected via the `:fleet_starfleet, :spawner_mod` seam to induce a failing pod count
  # (Spawner unreachable = restart mid-quiesce) without touching the real Spawner.
  # Named after the op that fails (`list_pods`): a `RaisingSpawner` homonym in fleet_spawner
  # raises on `spawn_pod` — same name, different contracts = reading trap (B6 dedup, renamed).
  defmodule RaisingOnCountSpawner do
    def list_pods, do: raise("Spawner unreachable (test E-05)")
  end

  defmodule ExitingOnCountSpawner do
    def list_pods, do: exit(:noproc)
  end

  setup do
    on_exit(&Quiesce.resume!/0)
    :ok
  end

  defp inject_spawner(mod),
    do: Fleet.Starfleet.TestEnv.put_env_restoring(:fleet_starfleet, :spawner_mod, mod)

  test "refuse_new_jobs/1 activates quiescence" do
    Quiesce.resume!()
    refute Quiesce.quiescing?()
    assert :ok = AggregateDispatcher.refuse_new_jobs(reason: :shutdown)
    assert Quiesce.quiescing?()
  end

  test "in_flight_count/0 returns an integer >= 0 (layering-resilient aggregate)" do
    # Direct Spawner.list_pods (filtered non-permanents) (Spawner started in the fleet_starfleet test
    # env → real count). fleet_task_queue is NOT a dep → app not started → `task_queue_running?` false
    # → `tasks_pending` returns an HONEST 0 (legitimate absence, not a masked failure) without logging
    # an error. So this test exercises the nominal path (no crash) in addition to the shape.
    n = AggregateDispatcher.in_flight_count()
    assert is_integer(n) and n >= 0
  end

  test "list_pods that RAISES → in_flight_count > 0 (fail-closed: drain CANNOT conclude 0)" do
    # E-05: Spawner present but unreachable (restart mid-quiesce). A `rescue -> 0` would undercount
    # → drain wrongly declared complete. Instead: a "not empty" sentinel.
    inject_spawner(RaisingOnCountSpawner)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "list_pods that EXITs (:noproc) → in_flight_count > 0 (no undercount)" do
    inject_spawner(ExitingOnCountSpawner)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "drain with AggregateDispatcher when list_pods RAISES → does not conclude :drained (timeout)" do
    # Integration: the real drain must NOT declare "empty" when the count is unavailable —
    # it consumes the grace window then proceeds (status :timeout), instead of a premature :drained.
    inject_spawner(RaisingOnCountSpawner)
    name = :"sd_e05_#{System.unique_integer([:positive])}"

    {:ok, _} =
      start_supervised({Fleet.Starfleet.Shutdown, name: name, dispatcher: AggregateDispatcher})

    assert :ok = Fleet.Starfleet.Shutdown.drain_in_flight(name: name, grace_ms: 200)
    assert %{status: :timeout} = :sys.get_state(name)
  end
end
