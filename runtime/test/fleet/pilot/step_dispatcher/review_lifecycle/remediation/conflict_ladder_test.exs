defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation.ConflictLadderTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation.ConflictLadder

  defp diag(totals), do: %{files: %{}, totals: totals}

  describe "tier0_decision (pure routing)" do
    test "all-semantic -> :chief — the producer is skipped ON EVIDENCE, the chief is not" do
      totals = %{trivial: 0, complex: 2, total: 2, all_trivial?: false, none_trivial?: true}
      # It used to answer `:escalate` and hand the case straight to the arch, jumping tiers 2 AND
      # 3 to immobilize a human. Skipping the PRODUCER is the point of the deterministic
      # pre-filter — the engine has just proven there is nothing shallow to fix, so a producer
      # round would burn a full run to rediscover it. Skipping the CHIEF was not: composing two
      # intentions that both passed their jury, on a branch the outsider did not write, IS its case.
      assert ConflictLadder.tier0_decision(diag(totals)) == :chief
    end

    test "all-WRITABLE -> :apply (auto-resolve)" do
      totals = %{
        trivial: 2,
        complex: 0,
        total: 2,
        writable: 2,
        all_trivial?: true,
        all_writable?: true,
        none_trivial?: false
      }

      assert ConflictLadder.tier0_decision(diag(totals)) == :apply
    end

    test "all-trivial but NOT all-writable -> :fall_through, not :apply" do
      # The distinction the write gate exists for: whitespace-only / reorder-only / competing
      # insertions are SHALLOW (a producer fixes them in one round) but not machine-writable, because
      # writing them needs a format assumption this engine refuses to make. Routing them to :apply
      # would spend a throwaway worktree and a merge to discover the engine declines — an outcome
      # known before the step runs. The producer HAS the context; it gets the round.
      totals = %{
        trivial: 2,
        complex: 0,
        total: 2,
        writable: 0,
        all_trivial?: true,
        all_writable?: false,
        none_trivial?: false
      }

      assert ConflictLadder.tier0_decision(diag(totals)) == :fall_through
    end

    test "mixed -> :fall_through (producer conflict-rework)" do
      totals = %{
        trivial: 1,
        complex: 1,
        total: 2,
        writable: 1,
        all_trivial?: false,
        all_writable?: false,
        none_trivial?: false
      }

      assert ConflictLadder.tier0_decision(diag(totals)) == :fall_through
    end

    test "no conflicts -> :fall_through" do
      totals = %{
        trivial: 0,
        complex: 0,
        total: 0,
        writable: 0,
        all_trivial?: false,
        all_writable?: false,
        none_trivial?: false
      }

      assert ConflictLadder.tier0_decision(diag(totals)) == :fall_through
    end
  end

  describe "exception_stage_decision (tier-2 gate before the arch)" do
    test "no gatekeeper pass yet -> :dispatch" do
      assert ConflictLadder.exception_stage_decision({:ok, 0}) == :dispatch
    end

    test "gatekeeper already tried -> :escalate" do
      assert ConflictLadder.exception_stage_decision({:ok, 1}) == :escalate
    end

    test "unreadable count -> :escalate (never a blind loop)" do
      assert ConflictLadder.exception_stage_decision({:error, :boom}) == :escalate
    end
  end
end
