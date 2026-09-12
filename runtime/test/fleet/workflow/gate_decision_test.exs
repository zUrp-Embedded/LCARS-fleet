defmodule Fleet.Workflow.GateDecisionTest do
  @moduledoc """
  Compares GateDecision vocabulary with priv/workflow/schema/gate-decision.json and validates
  parsed template examples. GateBrief and Pilot.StepRunConsumer share decisions/0.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.GateDecision

  test "decisions/0 = the 5 canon decisions" do
    assert GateDecision.decisions() ==
             ~w(continue abandon redirect escalate_user halt_wait_input)
  end

  test "the module is the EXACT mirror of the `decision` enum in the gate-decision.json wire schema" do
    schema =
      :lcars_fleet
      |> Application.app_dir("priv/workflow/schema/gate-decision.json")
      |> File.read!()
      |> Jason.decode!()

    schema_enum = get_in(schema, ["properties", "decision", "enum"])

    # SET equality (the JSON's order is not contractual, its content is).
    assert MapSet.new(schema_enum) == MapSet.new(GateDecision.decisions())
  end

  # Regression: an unspecified chain item shape led to object items rejected at #/chain/0.
  # Validate documented examples against the same schema as submitted decisions.
  test "every envelope example in the gate-brief templates validates against gate-decision.json" do
    schema =
      :lcars_fleet
      |> Application.app_dir("priv/workflow/schema/gate-decision.json")
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    templates = ["gate-brief-brief", "gate-brief-deliverable"]

    examples =
      for name <- templates,
          {field, json} <- envelope_examples(name) do
        {name, field, json}
      end

    # Require four total examples to avoid an empty loop; this does not enforce two per template.
    assert length(examples) == 2 * 2,
           "expected 2 documented examples per template, got: #{inspect(Enum.map(examples, fn {t, f, _} -> {t, f} end))}"

    for {name, field, json} <- examples do
      # Required fields are fixed; validate each optional-field example in a minimal envelope.
      envelope = %{"decision" => "continue", "reason" => "probe", field => json}

      assert :ok == ExJsonSchema.Validator.validate(schema, envelope),
             "#{name}.md documents a `#{field}` example the schema REFUSES: #{inspect(json)} — " <>
               inspect(ExJsonSchema.Validator.validate(schema, envelope))
    end
  end

  # Reads the first Example JSON per bullet; malformed/missing examples are skipped, then counted above.
  defp envelope_examples(name) do
    Fleet.Catalogue.brief_templates_root()
    |> Path.join(name <> ".md")
    |> File.read!()
    |> String.split("\n- `", trim: false)
    |> Enum.drop(1)
    |> Enum.flat_map(fn chunk ->
      with [field | _] <- String.split(chunk, "`", parts: 2),
           [_, rest] <- String.split(chunk, "Example: `", parts: 2),
           [json | _] <- String.split(rest, "`", parts: 2),
           {:ok, decoded} <- Jason.decode(json) do
        [{field, decoded}]
      else
        _ -> []
      end
    end)
  end
end
