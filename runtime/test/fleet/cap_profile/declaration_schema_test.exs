defmodule Fleet.CapProfile.DeclarationSchemaTest do
  @moduledoc """
  Proves that the canon template `priv/catalogue/cap_profile/config/declaration-template.json`
  validates against `priv/schema/declaration-v1.json`, and that an invalid config is rejected.
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([
                 __DIR__,
                 "..",
                 "..",
                 "..",
                 "priv",
                 "cap_profile",
                 "schema",
                 "declaration-v1.json"
               ])
  @canon_path Path.join([
                __DIR__,
                "..",
                "..",
                "..",
                "priv",
                "catalogue",
                "cap_profile",
                "config",
                "declaration-template.json"
              ])

  setup_all do
    assert File.exists?(@schema_path), "schema missing: #{@schema_path}"
    assert File.exists?(@canon_path), "canon declaration-template.json missing: #{@canon_path}"

    schema =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    canon = @canon_path |> File.read!() |> Jason.decode!()
    {:ok, schema: schema, canon: canon}
  end

  test "the canon declaration-template.json validates against declaration-v1.json", %{
    schema: schema,
    canon: canon
  } do
    assert :ok = ExJsonSchema.Validator.validate(schema, canon)
  end

  test "rejects — the RETIRED `level` and `nature` keys (crit_quarantine removed them from the schema)",
       %{schema: schema, canon: canon} do
    # They were valid fields once; `additionalProperties: false` now refuses them like any unknown
    # key. A legacy file still carrying `level` is schema-invalid — which is exactly why the READ
    # path (`Declaration.pipeline_default/2`) stopped full-validating and reads only the card name.
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, Map.put(canon, "level", "C2"))

    assert {:error, _} =
             ExJsonSchema.Validator.validate(schema, Map.put(canon, "nature", "web-gui"))
  end

  test "rejects — any structured block beyond the declared fields (a declaration IS exactly the schema)",
       %{schema: schema, canon: canon} do
    # The declaration carries justification + card + provenance, nothing else: any extra
    # non-underscore structure is refused (additionalProperties: false) — the WHY of the stakes
    # lives in the justification PROSE, never in side data.
    bad = Map.put(canon, "criteria", %{"anything" => true})
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "rejects — missing required field (justification)", %{schema: schema, canon: canon} do
    bad = Map.delete(canon, "justification")
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "accepts — the minimal declaration (required fields + card, no level)", %{schema: schema} do
    minimal = %{
      "_schema" => "lcars/declaration-v1",
      "declared_at" => "2026-08-23",
      "declared_by" => "architect",
      "justification" => "PoC jetable — carte c0-poc.",
      "pipeline_default" => "brief-gate"
    }

    assert :ok = ExJsonSchema.Validator.validate(schema, minimal)
  end

  test "rejects — unknown non-underscore key", %{schema: schema, canon: canon} do
    bad = Map.put(canon, "rogue", true)
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "accepts — additional informational underscore key", %{schema: schema, canon: canon} do
    ok = Map.put(canon, "_extra_note", "informational")
    assert :ok = ExJsonSchema.Validator.validate(schema, ok)
  end
end
