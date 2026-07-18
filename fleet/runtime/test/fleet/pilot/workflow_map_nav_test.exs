defmodule Fleet.Pilot.WorkflowMapNavTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.WorkflowMapNav

  # Linear poc-cycle-style WorkflowMap (Loader format: steps map keyed-by-name, string keys)
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
    test "single root (needs: []) → {:ok, {name, role}}" do
      assert {:ok, {"triage", "architect"}} = WorkflowMapNav.first_step(poc_cycle())
    end

    test "no root → {:error, :no_root}" do
      workflow_map = %{
        "steps" => %{
          "a" => %{"role" => "x", "needs" => ["b"]},
          "b" => %{"role" => "y", "needs" => ["a"]}
        }
      }

      assert {:error, :no_root} = WorkflowMapNav.first_step(workflow_map)
    end

    test "≥2 roots (parallel entry) → {:error, :multiple_roots}" do
      workflow_map = %{
        "steps" => %{
          "a" => %{"role" => "x", "needs" => []},
          "b" => %{"role" => "y", "needs" => []}
        }
      }

      assert {:error, :multiple_roots} = WorkflowMapNav.first_step(workflow_map)
    end
  end

  describe "next_step/2 — linear chain" do
    test "middle of chain → successor" do
      assert {:ok, {"refine", "consultant"}} = WorkflowMapNav.next_step(poc_cycle(), "triage")
      assert {:ok, {"build", "engineer"}} = WorkflowMapNav.next_step(poc_cycle(), "refine")
      assert {:ok, {"review", "reviewer"}} = WorkflowMapNav.next_step(poc_cycle(), "build")
      assert {:ok, {"seal", "starfleet"}} = WorkflowMapNav.next_step(poc_cycle(), "review")
    end

    test "last step → :terminal" do
      assert :terminal = WorkflowMapNav.next_step(poc_cycle(), "seal")
    end

    test "unknown step → {:error, :unknown_step}" do
      assert {:error, :unknown_step} = WorkflowMapNav.next_step(poc_cycle(), "nope")
    end

    test "≥2 successors (DAG, out of scope) → {:error, :dag_not_supported}" do
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
    test "role + spec of a known step" do
      assert {:ok, "engineer"} = WorkflowMapNav.step_role(poc_cycle(), "build")

      assert {:ok, %{"gate" => %{"type" => "hard"}}} =
               WorkflowMapNav.step_spec(poc_cycle(), "build")
    end

    test "same role on 2 steps — the NAME disambiguates (the DN §8 wrinkle)" do
      # standard-qa: architect on brainstorm AND plan
      workflow_map = %{
        "steps" => %{
          "brainstorm" => %{"role" => "architect", "needs" => []},
          "plan" => %{"role" => "architect", "needs" => ["brainstorm"]}
        }
      }

      # by name: unambiguous
      assert {:ok, {"plan", "architect"}} = WorkflowMapNav.next_step(workflow_map, "brainstorm")
      assert :terminal = WorkflowMapNav.next_step(workflow_map, "plan")
    end

    test "unknown step → :error" do
      assert :error = WorkflowMapNav.step_role(poc_cycle(), "nope")
      assert :error = WorkflowMapNav.step_spec(poc_cycle(), "nope")
    end
  end

  # B (§L441) — the `validate_explicit_step/1` tests are REMOVED with the function: a soft gate on
  # a business step is legitimate (gatekeeper escalation), not a malformed workflow_map.
  # cf. step_run_consumer_gate_test (escalation B).
end
