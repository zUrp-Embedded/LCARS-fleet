defmodule Fleet.Spawner.RestartStrategyTest do
  use ExUnit.Case, async: true

  test "one-shot maps to :temporary" do
    assert :temporary = Fleet.Spawner.restart_strategy_for("one-shot")
  end

  test "pipe maps to :transient" do
    assert :transient = Fleet.Spawner.restart_strategy_for("pipe")
  end

  test "run maps to :transient" do
    assert :transient = Fleet.Spawner.restart_strategy_for("run")
  end

  test "forever maps to :permanent" do
    assert :permanent = Fleet.Spawner.restart_strategy_for("forever")
  end

  test "unknown scope defaults to :temporary (safe default)" do
    assert :temporary = Fleet.Spawner.restart_strategy_for("invalid")
    assert :temporary = Fleet.Spawner.restart_strategy_for(nil)
  end
end
