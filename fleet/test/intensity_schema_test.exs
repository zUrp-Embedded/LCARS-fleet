defmodule Fleet.CapProfile.IntensitySchemaTest do
  @moduledoc """
  Proves that the canon template `priv/catalogue/cap_profile/canon/config/intensity-template.json`
  validates against `priv/schema/intensity-v1.json`, and that an invalid config is rejected.
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([__DIR__, "..", "priv", "cap_profile", "schema", "intensity-v1.json"])
  @canon_path Path.join([
                __DIR__,
                "..",
                "priv",
                "catalogue",
                "cap_profile",
                "canon",
                "config",
                "intensity-template.json"
              ])

  setup_all do
    assert File.exists?(@schema_path), "schema missing: #{@schema_path}"
    assert File.exists?(@canon_path), "canon intensity-template.json missing: #{@canon_path}"

    schema =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    canon = @canon_path |> File.read!() |> Jason.decode!()
    {:ok, schema: schema, canon: canon}
  end

  test "the canon intensity-template.json validates against intensity-v1.json", %{
    schema: schema,
    canon: canon
  } do
    assert :ok = ExJsonSchema.Validator.validate(schema, canon)
  end

  test "rejects — level outside enum C0-C4", %{schema: schema, canon: canon} do
    bad = Map.put(canon, "level", "C9")
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "rejects — any structured block beyond the declared fields (a declaration IS exactly the schema)",
       %{schema: schema, canon: canon} do
    # The declaration carries level + justification + card, nothing else: any extra
    # non-underscore structure is refused (additionalProperties: false) — the level's WHY
    # lives in the justification PROSE, never in side data.
    bad = Map.put(canon, "criteria", %{"anything" => true})
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "rejects — missing required field (justification)", %{schema: schema, canon: canon} do
    bad = Map.delete(canon, "justification")
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "accepts — declaration WITHOUT level (card-only declaration: absence recorded, never fabricated)",
       %{schema: schema, canon: canon} do
    ok = Map.delete(canon, "level")
    assert :ok = ExJsonSchema.Validator.validate(schema, ok)
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
