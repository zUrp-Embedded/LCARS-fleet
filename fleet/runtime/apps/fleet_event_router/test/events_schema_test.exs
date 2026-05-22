defmodule Fleet.EventRouter.EventsSchemaTest do
  @moduledoc """
  Lot 0bis — prouve que le canon `05_data-canon/config/events.yaml` valide
  contre le schéma dérivé `priv/schema/events-v1.json`, et qu'une config
  structurellement invalide est rejetée (ni trop strict, ni trop laxe).
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([__DIR__, "..", "priv", "schema", "events-v1.json"])
  @canon_path Path.join([
                __DIR__,
                "..",
                "..",
                "..",
                "..",
                "..",
                "05_data-canon",
                "config",
                "events.yaml"
              ])

  setup_all do
    assert File.exists?(@schema_path), "schema absent: #{@schema_path}"
    assert File.exists?(@canon_path), "canon events.yaml absent: #{@canon_path}"

    schema =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    {:ok, schema: schema}
  end

  test "le canon events.yaml valide contre events-v1.json", %{schema: schema} do
    canon = YamlElixir.read_from_file!(@canon_path)
    assert :ok = ExJsonSchema.Validator.validate(schema, canon)
  end

  test "config invalide rejetée — handler hors namespace Fleet.*", %{schema: schema} do
    bad = %{"events" => %{"pod.allocated" => ["NotFleet.Handler"]}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "config invalide rejetée — liste de handlers vide", %{schema: schema} do
    bad = %{"events" => %{"pod.allocated" => []}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "config invalide rejetée — event_type majuscule", %{schema: schema} do
    bad = %{"events" => %{"Pod.Allocated" => ["Fleet.Spawner.PodLifecycle"]}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "config invalide rejetée — clé racine inconnue", %{schema: schema} do
    bad = %{"events" => %{"tick" => ["Fleet.X"]}, "rogue" => true}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  # MIN-3 (reviewer Lot 0bis) : contrat minProperties:1 attesté en négatif.
  test "config invalide rejetée — events vide (minProperties:1)", %{schema: schema} do
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, %{"events" => %{}})
  end

  # MIN-1 (reviewer Lot 0bis) : pattern handler refuse le trailing dot.
  test "config invalide rejetée — handler trailing dot", %{schema: schema} do
    bad = %{"events" => %{"pod.allocated" => ["Fleet.Spawner."]}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end
end
