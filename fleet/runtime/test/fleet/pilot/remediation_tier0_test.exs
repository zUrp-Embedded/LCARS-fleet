defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.RemediationTier0Test do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation

  defp diag(totals), do: %{files: %{}, totals: totals}

  describe "tier0_decision (pure routing)" do
    test "all-semantic -> :escalate (skip the producer rounds)" do
      totals = %{trivial: 0, complex: 2, total: 2, all_trivial?: false, none_trivial?: true}
      assert Remediation.tier0_decision(diag(totals)) == :escalate
    end

    test "all-trivial -> :apply (auto-resolve)" do
      totals = %{trivial: 2, complex: 0, total: 2, all_trivial?: true, none_trivial?: false}
      assert Remediation.tier0_decision(diag(totals)) == :apply
    end

    test "mixed -> :fall_through (producer conflict-rework)" do
      totals = %{trivial: 1, complex: 1, total: 2, all_trivial?: false, none_trivial?: false}
      assert Remediation.tier0_decision(diag(totals)) == :fall_through
    end

    test "no conflicts -> :fall_through" do
      totals = %{trivial: 0, complex: 0, total: 0, all_trivial?: false, none_trivial?: false}
      assert Remediation.tier0_decision(diag(totals)) == :fall_through
    end
  end

  describe "gatekeeper_stage_decision (tier-2 gate before the arch)" do
    test "no gatekeeper pass yet -> :dispatch" do
      assert Remediation.gatekeeper_stage_decision({:ok, 0}) == :dispatch
    end

    test "gatekeeper already tried -> :escalate" do
      assert Remediation.gatekeeper_stage_decision({:ok, 1}) == :escalate
    end

    test "unreadable count -> :escalate (never a blind loop)" do
      assert Remediation.gatekeeper_stage_decision({:error, :boom}) == :escalate
    end
  end
end
