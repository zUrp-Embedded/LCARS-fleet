defmodule Fleet.Spawner.RecoveryTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod

  # DN-recovery B : `recovery_action/1` pure, fonction de la PHASE observée (pas
  # du scope — le scope joue au niveau orchestrateur). Sous `:temporary` le
  # supervisor ne ressuscite jamais ; plus de reprise implicite
  # `first_continue_for(:monitoring)` sur backend mort (LIFE-002).

  test "phase terminale → :release (rien à relancer)" do
    assert :release = Pod.recovery_action(:succeeded)
    assert :release = Pod.recovery_action(:released)
    assert :release = Pod.recovery_action(:killed)
  end

  test "phase en vol → :resume (reprend la session + re-launch, tout scope)" do
    assert :resume = Pod.recovery_action(:launching)
    assert :resume = Pod.recovery_action(:monitoring)
    assert :resume = Pod.recovery_action(:extracting)
    assert :resume = Pod.recovery_action(:releasing)
  end

  test "phase :failed / :pending / ambiguë → :recreate (from scratch, session neuve)" do
    assert :recreate = Pod.recovery_action(:failed)
    assert :recreate = Pod.recovery_action(:pending)
    assert :recreate = Pod.recovery_action(:allocating)
  end
end
