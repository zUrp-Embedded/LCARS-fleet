defmodule Fleet.MCP.SubmitResultSchemaTest do
  use ExUnit.Case, async: true

  # MESURE 2026-08-19 (banc, PR#34 et PR#37) : deux juges, trois verdicts, zéro `findings_v1`. La
  # consigne était dans leur SP ; ce qu'ils lisaient en AGISSANT était ce schéma, et il disait « un
  # objet ». Ce test tient la réparation : la forme de la charge machine est nommée LÀ où l'agent
  # remplit l'appel. Sans lui, un prochain nettoyage de schéma la retirerait sans rien casser de
  # visible — et la charge redisparaîtrait en silence, ce qui est précisément le mode de panne.
  test "le schéma de submit_result NOMME details.findings_v1 aux juges" do
    tool = Fleet.MCP.PodTools.get_tools()["submit_result"]
    schema = tool[:input_schema] || tool["input_schema"]
    payload = get_in(schema, ["properties", "payload"])
    desc = payload["description"]

    assert is_binary(desc), "payload sans description : l'agent ne lit qu'un `object` nu"
    assert desc =~ "findings_v1"
    assert desc =~ "severity"

    for sev <- Fleet.FindingsWire.severities() do
      assert desc =~ sev, "l'échelle citée au juge doit être CELLE du schéma, pas une variante"
    end

    # PERMISSIF par contrat : `submit_result` sert aussi les producteurs, dont le livrable n'a rien
    # d'un verdict. On nomme, on ne contraint pas.
    refute Map.has_key?(payload, "required")
    refute Map.get(payload, "additionalProperties") == false
  end
end
