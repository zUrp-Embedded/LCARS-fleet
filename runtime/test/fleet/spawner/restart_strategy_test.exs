defmodule Fleet.Spawner.RestartStrategyTest do
  use ExUnit.Case, async: true

  # Temporary children do not restart or consume supervisor restart intensity.
  # Respawning is explicit; lifetime_scope does not change the OTP restart policy.
  test "all scopes map to :temporary (B — supervisor never resurrects)" do
    assert :temporary = Fleet.Spawner.restart_strategy_for("one-shot")
    assert :temporary = Fleet.Spawner.restart_strategy_for("pipe")
    assert :temporary = Fleet.Spawner.restart_strategy_for("run")
    assert :temporary = Fleet.Spawner.restart_strategy_for("forever")
    assert :temporary = Fleet.Spawner.restart_strategy_for("invalid")
    assert :temporary = Fleet.Spawner.restart_strategy_for(nil)
  end
end
