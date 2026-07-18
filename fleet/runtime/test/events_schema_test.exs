defmodule Fleet.EventRouter.EventsSchemaTest do
  @moduledoc """
  Lot 0bis — prouve que le canon in-repo `priv/events.yaml` (chargé par le runtime,
  embarqué dans la release) valide contre le schéma dérivé `priv/schema/events-v1.json`,
  et qu'une config structurellement invalide est rejetée (ni trop strict, ni trop laxe).

  R0.3 fix : @canon_path pointait `05_data-canon/config/events.yaml` (chemin DOCTRINE,
  absent du repo de code post-bascule) → setup_all échouait → 7 tests invalid. Repointé
  sur le canon in-repo `priv/events.yaml` (single-source). Drift priv↔doctrine (47 vs 144 l)
  = data-side reconciliation.
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([__DIR__, "..", "priv", "event_router", "schema", "events-v1.json"])
  @canon_path Path.join([__DIR__, "..", "priv", "event_router", "events.yaml"])

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

  # R5/R08 — liste de handlers VIDE désormais VALIDE : un event peut être
  # registré (clé = authorized_event_type) sans handler dispatch, consommé par des
  # subscribers directs (WS, AuditConsumer, DriftMonitor). `minItems: 0`.
  test "config valide — liste de handlers vide (registré sans dispatch)", %{schema: schema} do
    ok = %{"events" => %{"pod.allocate" => []}}
    assert :ok = ExJsonSchema.Validator.validate(schema, ok)
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
