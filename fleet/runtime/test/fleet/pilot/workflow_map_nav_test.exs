defmodule Fleet.Pilot.WorkflowMapNavTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.WorkflowMapNav

  # WorkflowMap linéaire type poc-cycle (format Loader : steps map keyed-by-name, clés string)
  defp poc_cycle do
    %{
      "name" => "poc-cycle",
      "steps" => %{
        "triage" => %{"role" => "architect", "needs" => []},
        "refine" => %{"role" => "consultant", "needs" => ["triage"]},
        "build" => %{"role" => "engineer", "needs" => ["refine"], "gate" => %{"type" => "hard"}},
        "review" => %{"role" => "reviewer", "needs" => ["build"]},
        "seal" => %{"role" => "starfleet", "needs" => ["review"]}
      }
    }
  end

  describe "first_step/1" do
    test "racine unique (needs: []) → {:ok, {name, role}}" do
      assert {:ok, {"triage", "architect"}} = WorkflowMapNav.first_step(poc_cycle())
    end

    test "aucune racine → {:error, :no_root}" do
      workflow_map = %{
        "steps" => %{
          "a" => %{"role" => "x", "needs" => ["b"]},
          "b" => %{"role" => "y", "needs" => ["a"]}
        }
      }

      assert {:error, :no_root} = WorkflowMapNav.first_step(workflow_map)
    end

    test "≥2 racines (entrée parallèle) → {:error, :multiple_roots}" do
      workflow_map = %{
        "steps" => %{
          "a" => %{"role" => "x", "needs" => []},
          "b" => %{"role" => "y", "needs" => []}
        }
      }

      assert {:error, :multiple_roots} = WorkflowMapNav.first_step(workflow_map)
    end
  end

  describe "next_step/2 — chaîne linéaire" do
    test "milieu de chaîne → successeur" do
      assert {:ok, {"refine", "consultant"}} = WorkflowMapNav.next_step(poc_cycle(), "triage")
      assert {:ok, {"build", "engineer"}} = WorkflowMapNav.next_step(poc_cycle(), "refine")
      assert {:ok, {"review", "reviewer"}} = WorkflowMapNav.next_step(poc_cycle(), "build")
      assert {:ok, {"seal", "starfleet"}} = WorkflowMapNav.next_step(poc_cycle(), "review")
    end

    test "dernier step → :terminal" do
      assert :terminal = WorkflowMapNav.next_step(poc_cycle(), "seal")
    end

    test "step inconnu → {:error, :unknown_step}" do
      assert {:error, :unknown_step} = WorkflowMapNav.next_step(poc_cycle(), "nope")
    end

    test "≥2 successeurs (DAG, hors-scope) → {:error, :dag_not_supported}" do
      workflow_map = %{
        "steps" => %{
          "root" => %{"role" => "a", "needs" => []},
          "b1" => %{"role" => "b", "needs" => ["root"]},
          "b2" => %{"role" => "c", "needs" => ["root"]}
        }
      }

      assert {:error, :dag_not_supported} = WorkflowMapNav.next_step(workflow_map, "root")
    end
  end

  describe "step_role/2 + step_spec/2" do
    test "rôle + spec d'un step connu" do
      assert {:ok, "engineer"} = WorkflowMapNav.step_role(poc_cycle(), "build")
      assert {:ok, %{"gate" => %{"type" => "hard"}}} = WorkflowMapNav.step_spec(poc_cycle(), "build")
    end

    test "rôle d'un même rôle sur 2 steps — le NOM désambiguïse (le wrinkle DN §8)" do
      # standard-qa : architect sur brainstorm ET plan
      workflow_map = %{
        "steps" => %{
          "brainstorm" => %{"role" => "architect", "needs" => []},
          "plan" => %{"role" => "architect", "needs" => ["brainstorm"]}
        }
      }

      # par nom : sans ambiguïté
      assert {:ok, {"plan", "architect"}} = WorkflowMapNav.next_step(workflow_map, "brainstorm")
      assert :terminal = WorkflowMapNav.next_step(workflow_map, "plan")
    end

    test "step inconnu → :error" do
      assert :error = WorkflowMapNav.step_role(poc_cycle(), "nope")
      assert :error = WorkflowMapNav.step_spec(poc_cycle(), "nope")
    end
  end

  # B (§L441) — les tests de `validate_explicit_step/1` (biconditionnelle soft⟺gatekeeper,
  # A2.3b) sont RETIRÉS avec la fonction : une gate soft sur un step métier est légitime
  # (escalade gatekeeper), pas une workflow_map malformée. cf. step_run_consumer_gate_test (escalade B).
end
