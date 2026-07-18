defmodule Fleet.Coord.CoordPoliciesSchemaTest do
  @moduledoc """
  Proves that the in-repo canon `priv/config/coord-policies.yaml` (loaded by the
  runtime via `Fleet.Coord.Policies.init_policies!/0`, embedded in the release)
  validates against the schema `priv/schema/coord-policies-v1.json`, and that a
  structurally invalid config is rejected.

  @canon_path points to the in-repo canon (single-source, the file actually
  served) — NOT the doctrine path, which is absent from the code repo. The
  priv↔doctrine drift is a [DATA]-side reconciliation — canon alignment comes
  AFTER code validation, not before.
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([__DIR__, "..", "priv", "coord", "schema", "coord-policies-v1.json"])
  @canon_path Path.join([__DIR__, "..", "priv", "coord", "config", "coord-policies.yaml"])

  setup_all do
    assert File.exists?(@schema_path), "schema missing: #{@schema_path}"
    assert File.exists?(@canon_path), "canon coord-policies.yaml missing: #{@canon_path}"

    schema =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    {:ok, schema: schema}
  end

  test "the canon coord-policies.yaml validates against coord-policies-v1.json", %{schema: schema} do
    canon = YamlElixir.read_from_file!(@canon_path)
    assert :ok = ExJsonSchema.Validator.validate(schema, canon)
  end

  test "rejects — mapping without action", %{schema: schema} do
    bad = %{
      "mappings" => %{"audit.proven" => %{"escalation_path" => []}},
      "handoff_role_mapping" => %{"code" => "qualifier"}
    }

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "rejects — non-array escalation_path", %{schema: schema} do
    bad = %{
      "mappings" => %{
        "audit.proven" => %{"action" => "promote_artifact", "escalation_path" => "x"}
      },
      "handoff_role_mapping" => %{"code" => "qualifier"}
    }

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  # IMP-1 resolved by the reviewer's own conditional path: the canon has 10 TERMINAL
  # policies with escalation_path:[] (audit.proven / gatekeeper.* / phase_done.* /
  # *.proven). minItems:1 would have broken the canon (boot fail). Terminal semantics
  # documented (schema description) + POSITIVE test (not negative): [] accepted.
  test "accepts — empty escalation_path (terminal policy, canon-realistic)",
       %{schema: schema} do
    terminal = %{
      "mappings" => %{
        "audit.proven" => %{"action" => "promote_artifact", "escalation_path" => []}
      },
      "handoff_role_mapping" => %{"code" => "qualifier"}
    }

    assert :ok = ExJsonSchema.Validator.validate(schema, terminal)
  end

  test "rejects — mapping key without a dot", %{schema: schema} do
    bad = %{
      "mappings" => %{"auditproven" => %{"action" => "x", "escalation_path" => []}},
      "handoff_role_mapping" => %{"code" => "qualifier"}
    }

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  # handoff_role_mapping is OPTIONAL: the inter-role handoff (Fleet.Coord.Backend.Handoff)
  # is not wired yet, so the served canon (priv/config/coord-policies.yaml) legitimately
  # omits it. Same path as the escalation_path:[] case above (POSITIVE test, not negative).
  # To flip back to a rejection when the handler is implemented + the block reintegrated
  # ([DATA] reconciliation, doctrine).
  test "accepts — handoff_role_mapping absent (handoff not wired, canon-realistic)",
       %{schema: schema} do
    ok = %{"mappings" => %{"audit.proven" => %{"action" => "x", "escalation_path" => []}}}
    assert :ok = ExJsonSchema.Validator.validate(schema, ok)
  end
end
