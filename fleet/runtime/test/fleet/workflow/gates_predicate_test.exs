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

  describe "the grammar's real limits, measured 2026-08-05" do
    import ExUnit.CaptureLog

    test "a multi-word RHS is NOT a defect — it compares as the whole string" do
      # The moduledoc named this a "known limitation" for a year, and an audit reported it as a
      # defect on that basis. Both branches, so the note can never be re-derived from one.
      refute Predicate.eval?("severity_max != very critical", %{"severity_max" => "very critical"})

      assert Predicate.eval?("severity_max != very critical", %{"severity_max" => "important"})
    end

    test "`AND` INSIDE an operand splits the rule and answers WRONG — named, not fixed" do
      # "important" != "very AND critical" is TRUE. The conjunction is cut before any parsing, so
      # the rule becomes `severity_max != very` (true) AND the atom `critical` (false) → false.
      # The canon corpus has no such operand; fixing it needs quoting in the grammar. This test
      # exists so the day a workflow introduces one, the behaviour is documented rather than
      # discovered as a gate that rejects for no visible reason.
      refute Predicate.eval?("severity_max != very AND critical", %{"severity_max" => "important"})
    end

    test "a malformed comparison is LOUD — fail-closed is for missing evidence, not a broken rule" do
      log =
        capture_log(fn ->
          refute Predicate.eval?("tasks count >= 1", %{"tasks_count" => 5})
        end)

      assert log =~ "does not parse"
      assert log =~ "reject EVERY delivery"
    end

    test "INVERSE TWIN — a legitimate atom stays silent; the warning is not noise on every rule" do
      log =
        capture_log(fn ->
          assert Predicate.eval?("all_tests_pass", %{"all_tests_pass" => true})
          refute Predicate.eval?("absent_fact", %{})
        end)

      refute log =~ "does not parse"
    end

    test "a malformed rule still returns FALSE — the signal is added, the policy is unchanged" do
      capture_log(fn ->
        refute Predicate.eval?("tasks count >= 1", %{"tasks count >= 1" => false})
      end)
    end
  end
end
