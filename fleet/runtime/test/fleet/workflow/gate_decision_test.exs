defmodule Fleet.Workflow.GateDecisionTest do
  @moduledoc """
  Locks the single AUTHORITY over the gatekeeper vocabulary and its equality with the WIRE
  contract `priv/schema/gate-decision-v1.json`: if one drifts from the other, this test fails
  (anti-drift schema ⇔ code). `GateBrief` and `Fleet.Pilot.StepRunConsumer` both consume `decisions/0`.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.GateDecision

  test "decisions/0 = the 5 canon decisions" do
    assert GateDecision.decisions() ==
             ~w(continue abandon redirect escalate_user halt_wait_input)
  end

  test "the module is the EXACT mirror of the `decision` enum in the gate-decision-v1.json wire schema" do
    schema =
      :lcars_fleet
      |> Application.app_dir("priv/workflow/schema/gate-decision-v1.json")
      |> File.read!()
      |> Jason.decode!()

    schema_enum = get_in(schema, ["properties", "decision", "enum"])

    # SET equality (the JSON's order is not contractual, its content is).
    assert MapSet.new(schema_enum) == MapSet.new(GateDecision.decisions())
  end
end
