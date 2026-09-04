defmodule Fleet.Spawner.RestartStrategyTest do
  use ExUnit.Case, async: true

  # DN-recovery (option B): restart = `:temporary` for ALL scopes. The
  # DynamicSupervisor never resurrects; resurrection is a deliberate act of the
  # boot-orchestrator (`recovery_action/2`). Closes the 73rd (fleet-wide
  # cascade: `:temporary` children do not count toward the global restart
  # intensity). `lifetime_scope` drives recovery, not restart.
  test "all scopes map to :temporary (B — supervisor never resurrects)" do
    assert :temporary = Fleet.Spawner.restart_strategy_for("one-shot")
    assert :temporary = Fleet.Spawner.restart_strategy_for("pipe")
    assert :temporary = Fleet.Spawner.restart_strategy_for("run")
    assert :temporary = Fleet.Spawner.restart_strategy_for("forever")
    assert :temporary = Fleet.Spawner.restart_strategy_for("invalid")
    assert :temporary = Fleet.Spawner.restart_strategy_for(nil)
  end
end
