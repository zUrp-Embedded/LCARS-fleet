defmodule Fleet.EventRouter.EventsSchemaTest do
  @moduledoc """
  Proves that the in-repo canon `priv/events.yaml` (loaded by the runtime,
  embedded in the release) validates against the derived schema
  `priv/schema/events-v1.json`, and that a structurally invalid config is
  rejected (neither too strict nor too lax).

  @canon_path points to the in-repo canon (single-source, the file actually
  served) — NOT the doctrine path, absent from the code repo. The priv↔doctrine
  drift is a data-side reconciliation.
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([
                 __DIR__,
                 "..",
                 "..",
                 "..",
                 "priv",
                 "event_router",
                 "schema",
                 "events-v1.json"
               ])
  @canon_path Path.join([__DIR__, "..", "..", "..", "priv", "event_router", "events.yaml"])

  setup_all do
    assert File.exists?(@schema_path), "schema missing: #{@schema_path}"
    assert File.exists?(@canon_path), "canon events.yaml missing: #{@canon_path}"

    schema =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    {:ok, schema: schema}
  end

  test "the canon events.yaml validates against events-v1.json", %{schema: schema} do
    canon = YamlElixir.read_from_file!(@canon_path)
    assert :ok = ExJsonSchema.Validator.validate(schema, canon)
  end

  test "invalid config rejected — handler outside the Fleet.* namespace", %{schema: schema} do
    bad = %{"events" => %{"pod.allocated" => ["NotFleet.Handler"]}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  # R5/R08 — an EMPTY handler list is VALID: an event can be registered
  # (key = authorized_event_type) without a dispatch handler, consumed by direct
  # subscribers (WS, AuditConsumer). `minItems: 0`.
  test "valid config — empty handler list (registered without dispatch)", %{schema: schema} do
    ok = %{"events" => %{"pod.allocate" => []}}
    assert :ok = ExJsonSchema.Validator.validate(schema, ok)
  end

  test "invalid config rejected — uppercase event_type", %{schema: schema} do
    bad = %{"events" => %{"Pod.Allocated" => ["Fleet.Spawner.PodLifecycle"]}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "invalid config rejected — unknown root key", %{schema: schema} do
    bad = %{"events" => %{"tick" => ["Fleet.X"]}, "rogue" => true}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  # MIN-3: the minProperties:1 contract attested in the negative.
  test "invalid config rejected — empty events (minProperties:1)", %{schema: schema} do
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, %{"events" => %{}})
  end

  # MIN-1: the handler pattern refuses the trailing dot.
  test "invalid config rejected — handler trailing dot", %{schema: schema} do
    bad = %{"events" => %{"pod.allocated" => ["Fleet.Spawner."]}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end
end
