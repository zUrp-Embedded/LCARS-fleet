defmodule Fleet.Workflow.Gates.PredicateTest do
  @moduledoc """
  Gate rule predicate evaluator (R3). Covers the exact corpus of `standard-qa` /
  `audit-only` rule-strings + fail-closed on absent facts.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Gates.Predicate

  describe "boolean atoms (bare identifier)" do
    test "fact == true → true" do
      assert Predicate.eval?("all_tests_pass", %{"all_tests_pass" => true})
    end

    test "fact == false → false" do
      refute Predicate.eval?("all_tests_pass", %{"all_tests_pass" => false})
    end

    test "absent fact → false (fail-closed)" do
      refute Predicate.eval?("all_tests_pass", %{})
    end

    test "truthy non-boolean fact (string) → false (strict boolean)" do
      refute Predicate.eval?("all_tests_pass", %{"all_tests_pass" => "true"})
    end
  end

  describe "comparisons" do
    test "numeric >= satisfied / not satisfied" do
      assert Predicate.eval?("tasks_count >= 1", %{"tasks_count" => 3})
      refute Predicate.eval?("tasks_count >= 1", %{"tasks_count" => 0})
    end

    test "bareword equality != " do
      assert Predicate.eval?("severity_max != critical", %{"severity_max" => "important"})
      refute Predicate.eval?("severity_max != critical", %{"severity_max" => "critical"})
    end

    test "absent fact inside a comparison → false (fail-closed)" do
      refute Predicate.eval?("severity_max != critical", %{})
      refute Predicate.eval?("tasks_count >= 1", %{})
    end

    test "fact present as nil → false (nil ≡ absent; the `nil != critical` trap)" do
      refute Predicate.eval?("severity_max != critical", %{"severity_max" => nil})
    end

    test "incompatible type (>= on a non-number) → false (fail-closed)" do
      refute Predicate.eval?("tasks_count >= 1", %{"tasks_count" => "many"})
    end
  end

  describe "AND conjunction" do
    test "all true → true" do
      assert Predicate.eval?(
               "spec_doc_exists AND spec_doc_non_empty",
               %{"spec_doc_exists" => true, "spec_doc_non_empty" => true}
             )
    end

    test "one false term → false" do
      refute Predicate.eval?(
               "spec_doc_exists AND spec_doc_non_empty",
               %{"spec_doc_exists" => true, "spec_doc_non_empty" => false}
             )
    end

    test "atom AND comparison (plan corpus)" do
      assert Predicate.eval?(
               "plan_doc_exists AND tasks_count >= 1",
               %{"plan_doc_exists" => true, "tasks_count" => 2}
             )

      refute Predicate.eval?(
               "plan_doc_exists AND tasks_count >= 1",
               %{"plan_doc_exists" => true, "tasks_count" => 0}
             )
    end
  end

  describe "fail-closed totality (non-string rule / non-map outputs → false, no crash)" do
    test "non-string rule (map) → false (the hard gate calls eval? on unfiltered items)" do
      refute Predicate.eval?(%{"name" => "r1"}, %{"all_tests_pass" => true})
    end

    test "non-string rule (integer) → false" do
      refute Predicate.eval?(42, %{"all_tests_pass" => true})
    end

    test "string rule but non-map outputs → false (never FunctionClauseError)" do
      refute Predicate.eval?("all_tests_pass", "not a map")
      refute Predicate.eval?("all_tests_pass", nil)
    end
  end
end
