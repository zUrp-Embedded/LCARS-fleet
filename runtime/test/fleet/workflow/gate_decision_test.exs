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

  # The judge learns the envelope from the gate-brief template and NOWHERE else. The template used
  # to write `"chain": [...]` with no item type; the schema enforces strings, so judges filled it
  # with objects and EVERY brief-gate step run died `halt_invalid` on `#/chain/0` — fail-closed and
  # silent about the cause, because the doc and the schema never met.
  # This is the meeting: the examples the template hands the judge are validated against the very
  # schema that will refuse them. Prose that instructs is anchored to the mechanism that enforces
  # it, or it is a guess with a nice font.
  test "every envelope example in the gate-brief templates validates against gate-decision-v1.json" do
    schema =
      :lcars_fleet
      |> Application.app_dir("priv/workflow/schema/gate-decision-v1.json")
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    templates = ["gate-brief-brief", "gate-brief-deliverable"]

    examples =
      for name <- templates,
          {field, json} <- envelope_examples(name) do
        {name, field, json}
      end

    # The templates document exactly the two optional fields whose shape is enforced. A template
    # that stopped documenting them would pass a per-example loop vacuously.
    assert length(examples) == 2 * 2,
           "expected 2 documented examples per template, got: #{inspect(Enum.map(examples, fn {t, f, _} -> {t, f} end))}"

    for {name, field, json} <- examples do
      # A minimal VALID envelope carrying only the example under test: the required fields are
      # constants here, so any failure names the example, never the scaffolding.
      envelope = %{"decision" => "continue", "reason" => "probe", field => json}

      assert :ok == ExJsonSchema.Validator.validate(schema, envelope),
             "#{name}.md documents a `#{field}` example the schema REFUSES: #{inspect(json)} — " <>
               inspect(ExJsonSchema.Validator.validate(schema, envelope))
    end
  end

  # Reads the ``Example: `<json>` `` lines of a template and returns {field, decoded}. The field is
  # the bullet's own name (`- \`chain\` — …`), so a renamed field is not silently skipped.
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
