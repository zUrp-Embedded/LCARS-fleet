defmodule Fleet.MCP.SubmitResultSchemaTest do
  use ExUnit.Case, async: true

  # Keep judge findings guidance in the schema read at call time; startup prompt
  # guidance alone did not reliably produce machine-readable findings in bench runs.
  test "le schéma de submit_result NOMME details.findings aux juges" do
    tool = Fleet.MCP.PodTools.get_tools()["submit_result"]
    schema = tool[:input_schema] || tool["input_schema"]
    payload = get_in(schema, ["properties", "payload"])
    desc = payload["description"]

    assert is_binary(desc), "payload sans description : l'agent ne lit qu'un `object` nu"
    assert desc =~ "findings"
    assert desc =~ "severity"

    for sev <- Fleet.FindingsWire.severities() do
      assert desc =~ sev, "l'échelle citée au juge doit être CELLE du schéma, pas une variante"
    end

    # Keep payload fields permissive because submit_result also serves producer deliverables.
    refute Map.has_key?(payload, "required")
    refute Map.get(payload, "additionalProperties") == false
  end
end
