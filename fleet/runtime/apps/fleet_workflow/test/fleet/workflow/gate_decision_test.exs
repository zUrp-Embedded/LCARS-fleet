defmodule Fleet.Workflow.GateDecisionTest do
  @moduledoc """
  Verrouille l'AUTORITÉ unique du vocabulaire gatekeeper et son égalité avec le contrat WIRE
  `priv/schema/gate-decision-v1.json` : si l'un dérive de l'autre, ce test échoue (anti-drift
  schema ⇔ code). `GateBrief` et `Fleet.Pilot.StepRunConsumer` consomment tous deux `decisions/0`.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.GateDecision

  test "decisions/0 = les 5 décisions canon" do
    assert GateDecision.decisions() ==
             ~w(continue abandon redirect escalate_user halt_wait_input)
  end

  test "le module est le miroir EXACT de l'enum `decision` du schema wire gate-decision-v1.json" do
    schema =
      :fleet_workflow
      |> Application.app_dir("priv/schema/gate-decision-v1.json")
      |> File.read!()
      |> Jason.decode!()

    schema_enum = get_in(schema, ["properties", "decision", "enum"])

    # Égalité d'ENSEMBLE (l'ordre du JSON n'est pas contractuel, le contenu l'est).
    assert MapSet.new(schema_enum) == MapSet.new(GateDecision.decisions())
  end
end
