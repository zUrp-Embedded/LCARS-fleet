defmodule Fleet.Pilot.StepRunConsumer.GateEngineTest do
  @moduledoc """
  `GateEngine`'s pure edges, addressed where they live: the producer fact (`producer?/4`), what a
  step advances to (`advance_intent/3`), and the fact handed DOWN by the consumer — resolved once
  per step-run and never re-derived here. The gate decisions themselves run end to end in
  `step_run_consumer_gate_test`; `system_over_declared/3` in `gate_engine_system_outputs_test`.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunConsumer.GateEngine
  alias Fleet.Pilot.StepRunConsumer.GateEngine.Seams

  # A linear card: build is not terminal, seal is.
  defp card do
    %{
      "name" => "linear",
      "steps" => %{
        "build" => %{"role" => "engineer", "needs" => []},
        "seal" => %{"role" => "reviewer", "needs" => ["build"]}
      }
    }
  end

  defp seams(mode_fun) do
    %Seams{
      loader: fn _name -> card() end,
      deliverable_mode_fun: mode_fun,
      escalation: nil
    }
  end

  describe "producer?/4 — the effective mode wins, the resolver is the fallback" do
    test "an effective deliverable_mode decides without touching the resolver" do
      raising = fn _role, _root -> raise "must not be called" end
      assert {:ok, true} = GateEngine.producer?("engineer", raising, "git_native", nil)
      assert {:ok, false} = GateEngine.producer?("reviewer", raising, "payload", nil)
    end

    test "without an effective mode, the resolver answers for the role" do
      resolver = fn "engineer", _root -> {:ok, "git_native"} end
      assert {:ok, true} = GateEngine.producer?("engineer", resolver, nil, nil)
    end

    test "a nil role is nobody's producer" do
      assert {:ok, false} = GateEngine.producer?(nil, fn _, _ -> raise "unused" end, nil, nil)
    end
  end

  describe "advance_intent/3 — terminal producer → :review, terminal judge → :promote, else :advance" do
    test "from a non-terminal step: :advance with the next (role, step)" do
      assert {:ok, :advance, {"reviewer", "seal"}} =
               GateEngine.advance_intent(card(), "build", true)
    end

    test "from the terminal step: the producer goes to review, the judge to promote" do
      assert {:ok, :review, {nil, nil}} = GateEngine.advance_intent(card(), "seal", true)
      assert {:ok, :promote, {nil, nil}} = GateEngine.advance_intent(card(), "seal", false)
    end
  end

  describe "resolve_next/4 — the fact handed down is read, never re-derived" do
    test "with producer? given, a card-less payload resolves without calling the mode resolver" do
      raising = fn _role, _root ->
        raise "producer? was handed down — the resolver must not be called"
      end

      payload = %{"role" => "engineer", "repo" => "o/r"}

      assert {:ok, :review, {nil, nil}} =
               GateEngine.resolve_next(payload, 1, seams(raising), true)

      assert {:ok, :reviewed, {nil, nil}} =
               GateEngine.resolve_next(payload, 1, seams(raising), false)
    end

    test "with producer? given, a step WITH a card passes its gate and advances without the resolver" do
      raising = fn _role, _root ->
        raise "producer? was handed down — the resolver must not be called"
      end

      payload = %{
        "role" => "engineer",
        "repo" => "o/r",
        "workflow_map" => "linear",
        "step" => "build",
        "result" => %{}
      }

      assert {:ok, :advance, {"reviewer", "seal"}} =
               GateEngine.resolve_next(payload, 1, seams(raising), true)
    end

    test "without the fact (a direct caller), the resolver is consulted" do
      resolver = fn "engineer", _root -> {:ok, "git_native"} end
      payload = %{"role" => "engineer", "repo" => "o/r"}

      assert {:ok, :review, {nil, nil}} = GateEngine.resolve_next(payload, 1, seams(resolver))
    end
  end
end
