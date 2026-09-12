defmodule Fleet.Spawner.RecoveryTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.Recovery

  test "terminal phase → :release (nothing to relaunch)" do
    assert :release = Recovery.recovery_action(:succeeded)
    assert :release = Recovery.recovery_action(:released)
    assert :release = Recovery.recovery_action(:killed)
  end

  test "phase :failed / :pending / ambiguous → :recreate (from scratch, fresh session)" do
    assert :recreate = Recovery.recovery_action(:failed)
    assert :recreate = Recovery.recovery_action(:pending)
    assert :recreate = Recovery.recovery_action(:allocating)
  end

  test "IN-FLIGHT phase → :recreate (backend dead under :temporary, dead session unrecoverable)" do
    assert :recreate = Recovery.recovery_action(:launching)
    assert :recreate = Recovery.recovery_action(:monitoring)
    assert :recreate = Recovery.recovery_action(:extracting)
    assert :recreate = Recovery.recovery_action(:releasing)
  end
end
