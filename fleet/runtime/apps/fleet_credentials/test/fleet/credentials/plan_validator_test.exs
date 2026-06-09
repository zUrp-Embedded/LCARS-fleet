defmodule Fleet.Credentials.PlanValidatorTest do
  use ExUnit.Case, async: true

  alias Fleet.Credentials.PlanValidator

  test "plans payants reconnus (source CC : max/pro/team/enterprise) → :ok" do
    for plan <- ~w(max pro team enterprise) do
      assert PlanValidator.validate(plan) == :ok, "#{plan} devrait être accepté"
    end
  end

  test "insensible à la casse" do
    assert PlanValidator.validate("Max") == :ok
    assert PlanValidator.validate("PRO") == :ok
    assert PlanValidator.validate("Enterprise") == :ok
  end

  test "plan non-payant / inconnu → {:error, {:invalid_plan, type}} (type conservé)" do
    assert PlanValidator.validate("free") == {:error, {:invalid_plan, "free"}}
    assert PlanValidator.validate("") == {:error, {:invalid_plan, ""}}
    assert PlanValidator.validate("bogus") == {:error, {:invalid_plan, "bogus"}}
  end
end
