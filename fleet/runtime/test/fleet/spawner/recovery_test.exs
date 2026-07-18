defmodule Fleet.Spawner.RecoveryTest do
  # async: true — `recovery_action/1` is pure (function of the phase alone); no
  # global config mutation (the `:recovery_resume_enabled` gate is gone).
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.Recovery

  # `recovery_action/1` is pure: the PHASE alone decides. Terminal phase → :release
  # (nothing to relaunch); everything else → :recreate (from scratch, fresh session).
  # No `:resume` path: `--resume` on a server-side dead session = zombie pod
  # (proven live). An in-flight (re)spawn rerolls; the task stays in the queue and
  # re-drives a fresh REPL. Under `:temporary` the supervisor never resurrects;
  # deliberate (re)spawn → explicit decision.

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
