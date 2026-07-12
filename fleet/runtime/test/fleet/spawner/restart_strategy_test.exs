defmodule Fleet.Spawner.RestartStrategyTest do
  use ExUnit.Case, async: true

  # DN-recovery (option B, 2026-06-06) : restart = `:temporary` pour TOUS les
  # scopes. Le DynamicSupervisor ne ressuscite jamais ; la résurrection est un
  # acte délibéré du boot-orchestrator (`recovery_action/2`). Ferme le 73e
  # (cascade fleet-wide : les enfants `:temporary` ne comptent pas dans
  # l'intensité globale). `lifetime_scope` pilote la recovery, pas le restart.
  test "tous les scopes mappent vers :temporary (B — supervisor ne ressuscite jamais)" do
    assert :temporary = Fleet.Spawner.restart_strategy_for("one-shot")
    assert :temporary = Fleet.Spawner.restart_strategy_for("pipe")
    assert :temporary = Fleet.Spawner.restart_strategy_for("run")
    assert :temporary = Fleet.Spawner.restart_strategy_for("forever")
    assert :temporary = Fleet.Spawner.restart_strategy_for("invalid")
    assert :temporary = Fleet.Spawner.restart_strategy_for(nil)
  end
end
