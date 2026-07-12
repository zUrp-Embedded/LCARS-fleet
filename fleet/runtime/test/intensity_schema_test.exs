defmodule Fleet.CapProfile.IntensitySchemaTest do
  @moduledoc """
  Lot 0bis — prouve que le canon template `priv/canon/config/intensity-template.json` (réabsorbé R0.7)
  valide contre `priv/schema/intensity-v1.json`, et qu'une config invalide est rejetée.
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([__DIR__, "..", "priv", "schema", "intensity-v1.json"])
  @canon_path Path.join([__DIR__, "..", "priv", "canon", "config", "intensity-template.json"])

  setup_all do
    assert File.exists?(@schema_path), "schema absent: #{@schema_path}"
    assert File.exists?(@canon_path), "canon intensity-template.json absent: #{@canon_path}"

    schema =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    canon = @canon_path |> File.read!() |> Jason.decode!()
    {:ok, schema: schema, canon: canon}
  end

  test "le canon intensity-template.json valide contre intensity-v1.json", %{
    schema: schema,
    canon: canon
  } do
    assert :ok = ExJsonSchema.Validator.validate(schema, canon)
  end

  test "rejet — level hors enum L0-L4", %{schema: schema, canon: canon} do
    bad = Map.put(canon, "level", "L9")
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "rejet — criteria.multi_authors non-booléen", %{schema: schema, canon: canon} do
    bad = put_in(canon, ["criteria", "multi_authors"], "yes")
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "rejet — champ requis manquant (justification)", %{schema: schema, canon: canon} do
    bad = Map.delete(canon, "justification")
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "rejet — clé inconnue non-underscore", %{schema: schema, canon: canon} do
    bad = Map.put(canon, "rogue", true)
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "accepte — clé underscore informationnelle additionnelle", %{schema: schema, canon: canon} do
    ok = Map.put(canon, "_extra_note", "informational")
    assert :ok = ExJsonSchema.Validator.validate(schema, ok)
  end
end
