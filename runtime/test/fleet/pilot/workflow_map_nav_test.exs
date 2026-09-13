defmodule Fleet.Pilot.WorkflowMapNavTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.WorkflowMapNav

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
      workflow_map = %{
        "steps" => %{
          "brainstorm" => %{"role" => "architect", "needs" => []},
          "plan" => %{"role" => "architect", "needs" => ["brainstorm"]}
        }
      }

      assert {:ok, {"plan", "architect"}} = WorkflowMapNav.next_step(workflow_map, "brainstorm")
      assert :terminal = WorkflowMapNav.next_step(workflow_map, "plan")
    end

    test "unknown step → :error" do
      assert :error = WorkflowMapNav.step_role(poc_cycle(), "nope")
      assert :error = WorkflowMapNav.step_spec(poc_cycle(), "nope")
    end
  end

  # Soft business gates are valid; their escalation is exercised in step_run_consumer_gate_test.

  describe "safe_load/3 — the opts say WHICH catalogue answers (characterisation)" do
    # Exercise function/module arities. Catalogue selection at production call sites has
    # separate rail tests and the workflow.loader_arity contract.
    defmodule BinaryLoader do
      def load!(name, opts), do: %{"name" => name, "opts" => opts}
    end

    defmodule UnaryLoader do
      def load!(name), do: %{"name" => name}
    end

    test "a binary FUNCTION receives the opts" do
      loader = fn name, opts -> %{"name" => name, "opts" => opts} end

      assert {:ok, %{"name" => "wfmap/standard", "opts" => [catalogue_root: "/c"]}} =
               WorkflowMapNav.safe_load(loader, "wfmap/standard", catalogue_root: "/c")
    end

    test "a unary FUNCTION is honoured (every stub), the opts are dropped" do
      assert {:ok, %{"name" => "wfmap/standard"}} =
               WorkflowMapNav.safe_load(fn name -> %{"name" => name} end, "wfmap/standard",
                 catalogue_root: "/c"
               )
    end

    test "a MODULE exporting load!/2 receives the opts; one exporting load!/1 only is honoured" do
      assert {:ok, %{"opts" => [catalogue_root: "/c"]}} =
               WorkflowMapNav.safe_load(BinaryLoader, "x", catalogue_root: "/c")

      assert {:ok, %{"name" => "x"}} =
               WorkflowMapNav.safe_load(UnaryLoader, "x", catalogue_root: "/c")
    end

    test "a raising loader is normalized, never a crash on the rail" do
      assert {:error, {:workflow_map_load_failed, "x", "boom"}} =
               WorkflowMapNav.safe_load(fn _n, _o -> raise "boom" end, "x", [])
    end
  end
end
