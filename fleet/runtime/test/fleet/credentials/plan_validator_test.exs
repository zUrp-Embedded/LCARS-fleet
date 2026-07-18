defmodule Fleet.Credentials.PlanValidatorTest do
  use ExUnit.Case, async: true

  alias Fleet.Credentials.PlanValidator

  test "recognized paid plans (CC source: max/pro/team/enterprise) → :ok" do
    for plan <- ~w(max pro team enterprise) do
      assert PlanValidator.validate(plan) == :ok, "#{plan} should be accepted"
    end
  end

  test "case-insensitive" do
    assert PlanValidator.validate("Max") == :ok
    assert PlanValidator.validate("PRO") == :ok
    assert PlanValidator.validate("Enterprise") == :ok
  end

  test "non-paid / unknown plan → {:error, {:invalid_plan, type}} (type preserved)" do
    assert PlanValidator.validate("free") == {:error, {:invalid_plan, "free"}}
    assert PlanValidator.validate("") == {:error, {:invalid_plan, ""}}
    assert PlanValidator.validate("bogus") == {:error, {:invalid_plan, "bogus"}}
  end

  test "R1-37: TOTAL validator — non-binary plan (nil/integer/atom) → typed refusal, no crash" do
    assert PlanValidator.validate(nil) == {:error, {:invalid_plan, nil}}
    assert PlanValidator.validate(0) == {:error, {:invalid_plan, 0}}
    assert PlanValidator.validate(:max) == {:error, {:invalid_plan, :max}}
  end
end
