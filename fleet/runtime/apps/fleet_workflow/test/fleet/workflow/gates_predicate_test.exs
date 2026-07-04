defmodule Fleet.Workflow.Gates.PredicateTest do
  @moduledoc """
  Évaluateur de prédicats gate v2.5 (R3). Couvre le corpus exact des
  rule-strings `standard-qa` / `audit-only` + le fail-closed sur faits absents.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Gates.Predicate

  describe "atomes booléens (identifiant nu)" do
    test "fait == true → vrai" do
      assert Predicate.eval?("all_tests_pass", %{"all_tests_pass" => true})
    end

    test "fait == false → faux" do
      refute Predicate.eval?("all_tests_pass", %{"all_tests_pass" => false})
    end

    test "fait absent → faux (fail-closed)" do
      refute Predicate.eval?("all_tests_pass", %{})
    end

    test "fait truthy non-booléen (string) → faux (booléen strict)" do
      refute Predicate.eval?("all_tests_pass", %{"all_tests_pass" => "true"})
    end
  end

  describe "comparaisons" do
    test "numérique >= satisfait / non satisfait" do
      assert Predicate.eval?("tasks_count >= 1", %{"tasks_count" => 3})
      refute Predicate.eval?("tasks_count >= 1", %{"tasks_count" => 0})
    end

    test "égalité bareword != " do
      assert Predicate.eval?("severity_max != critical", %{"severity_max" => "important"})
      refute Predicate.eval?("severity_max != critical", %{"severity_max" => "critical"})
    end

    test "fait absent dans une comparaison → faux (fail-closed)" do
      refute Predicate.eval?("severity_max != critical", %{})
      refute Predicate.eval?("tasks_count >= 1", %{})
    end

    test "fait présent à nil → faux (nil ≡ absent ; piège `nil != critical`)" do
      refute Predicate.eval?("severity_max != critical", %{"severity_max" => nil})
    end

    test "type incompatible (>= sur non-nombre) → faux (fail-closed)" do
      refute Predicate.eval?("tasks_count >= 1", %{"tasks_count" => "beaucoup"})
    end
  end

  describe "conjonction AND" do
    test "tous vrais → vrai" do
      assert Predicate.eval?(
               "spec_doc_exists AND spec_doc_non_empty",
               %{"spec_doc_exists" => true, "spec_doc_non_empty" => true}
             )
    end

    test "un terme faux → faux" do
      refute Predicate.eval?(
               "spec_doc_exists AND spec_doc_non_empty",
               %{"spec_doc_exists" => true, "spec_doc_non_empty" => false}
             )
    end

    test "atom AND comparaison (corpus plan)" do
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

  describe "totalité fail-closed (rule non-string / outputs non-map → false, pas de crash)" do
    test "rule non-string (map) → faux (le hard gate appelle eval? sur des items non filtrés)" do
      refute Predicate.eval?(%{"name" => "r1"}, %{"all_tests_pass" => true})
    end

    test "rule non-string (entier) → faux" do
      refute Predicate.eval?(42, %{"all_tests_pass" => true})
    end

    test "rule string mais outputs non-map → faux (jamais FunctionClauseError)" do
      refute Predicate.eval?("all_tests_pass", "pas une map")
      refute Predicate.eval?("all_tests_pass", nil)
    end
  end
end
