defmodule Fleet.Starfleet.Shutdown.AggregateDispatcherTest do
  @moduledoc """
  Backend RÉEL du seam `:shutdown_dispatcher` (brique R4 D5 2/3). async: false :
  `refuse_new_jobs` mute le flag global `Fleet.Shutdown.Quiesce` — on_exit
  resume! impératif.
  """
  use ExUnit.Case, async: false

  alias Fleet.Starfleet.Shutdown.AggregateDispatcher
  alias Fleet.Shutdown.Quiesce

  setup do
    on_exit(&Quiesce.resume!/0)
    :ok
  end

  test "refuse_new_jobs/1 active la quiescence" do
    Quiesce.resume!()
    refute Quiesce.quiescing?()
    assert :ok = AggregateDispatcher.refuse_new_jobs(reason: :shutdown)
    assert Quiesce.quiescing?()
  end

  test "in_flight_count/0 rend un entier >= 0 (agrégat résilient layering)" do
    # Spawner.count_pods direct ; Pipeline/TaskQueue par dispatch dynamique
    # guardé. Dans l'env test fleet_starfleet, fleet_pipeline/fleet_task_queue
    # ne sont pas démarrés (non-deps) → leurs Registry/GenServer absents →
    # `dyn/3` rabat sur `catch :exit`/`:unavailable` → 0. Ce test EXERCE donc
    # bien le chemin de résilience (pas de crash) en plus de la forme.
    n = AggregateDispatcher.in_flight_count()
    assert is_integer(n) and n >= 0
  end
end
