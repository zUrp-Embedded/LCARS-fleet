defmodule Fleet.Workflow.GraphValidatorTest do
  @moduledoc """
  PURE graph linter (data → decision), tested without files (`async: true`).
  Covers every invariant: well-formed workflow_map → :ok; each violation → its `kind`.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.GraphValidator

  # Minimal step spec. `needs` omitted = root (the Loader normalizes absent `needs` → []).
  defp step(needs \\ nil) do
    base = %{"role" => "noop"}
    if needs, do: Map.put(base, "needs", needs), else: base
  end

  describe "well-formed workflow_map → :ok" do
    test "single step (root == terminal)" do
      assert GraphValidator.validate(%{"only" => step()}) == :ok
    end

    test "linear chain root → terminal" do
      steps = %{
        "a" => step(),
        "b" => step(["a"]),
        "c" => step(["b"])
      }

      assert GraphValidator.validate(steps) == :ok
    end
  end

  describe "root" do
    test "0 root (fully cyclic graph) → :no_root" do
      steps = %{"a" => step(["b"]), "b" => step(["a"])}
      assert {:error, {:no_root, _}} = GraphValidator.validate(steps)
    end

    test "≥2 roots → :multiple_roots (with the names)" do
      steps = %{"a" => step(), "b" => step(), "c" => step(["a", "b"])}
      assert {:error, {:multiple_roots, %{roots: ["a", "b"]}}} = GraphValidator.validate(steps)
    end
  end

  describe "phantom needs (phantom edge)" do
    test "needs referring to an undeclared step → :phantom_edge (step + offending needs)" do
      steps = %{"a" => step(), "b" => step(["implment"])}

      assert {:error, {:phantom_edge, %{step: "b", needs: "implment"}}} =
               GraphValidator.validate(steps)
    end
  end

  describe "acyclicity" do
    test "cycle ON the chain (reachable from the root) → :cycle" do
      # root r → a → b → a (b loops back to a). r is root; a,b reachable; cycle a↔b.
      steps = %{
        "r" => step(),
        "a" => step(["r", "b"]),
        "b" => step(["a"])
      }

      assert {:error, {:cycle, %{steps: cyclic}}} = GraphValidator.validate(steps)
      assert "a" in cyclic and "b" in cyclic
    end

    test "no terminal (the chain loops, no step without successor) → rejected" do
      # For this sequential runtime, "no reachable terminal" == "cycle":
      # a chain r → a → b → a has no terminal step. Rejected as :cycle.
      steps = %{"r" => step(), "a" => step(["r", "b"]), "b" => step(["a"])}
      assert {:error, {:cycle, _}} = GraphValidator.validate(steps)
    end
  end

  describe "reachability" do
    test "orphan component (disconnected from the root) → :unreachable" do
      # r alone = main chain; x↔y form a disconnected blob (not reachable
      # from r). Diagnosed :unreachable (missing wiring) BEFORE acyclicity.
      steps = %{
        "r" => step(),
        "x" => step(["y"]),
        "y" => step(["x"])
      }

      assert {:error, {:unreachable, %{steps: orphans}}} = GraphValidator.validate(steps)
      assert "x" in orphans and "y" in orphans
    end
  end

  describe "fan-out (parallel branch, out of sequential scope)" do
    test "a step with ≥2 successors → :fan_out" do
      # a has two successors (b and c) → parallel branch, rejected (sequential runtime).
      steps = %{
        "a" => step(),
        "b" => step(["a"]),
        "c" => step(["a"])
      }

      assert {:error, {:fan_out, %{step: "a", successors: ["b", "c"]}}} =
               GraphValidator.validate(steps)
    end
  end

  describe "describe/1 — readable message per invariant" do
    test "phantom_edge names the step and the offending needs" do
      msg = GraphValidator.describe({:phantom_edge, %{step: "build", needs: "foo"}})
      assert msg =~ "phantom edge"
      assert msg =~ "build"
      assert msg =~ "foo"
    end
  end
end
