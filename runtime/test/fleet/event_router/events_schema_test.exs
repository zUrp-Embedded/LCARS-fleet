defmodule Fleet.EventRouter.EventsSchemaTest do
  @moduledoc """
  Validates shipped priv/event_router/events.yaml against its events.json schema and
  selected malformed inputs. Negative examples may violate multiple schema constraints;
  they do not isolate every reason named in their historical titles.
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
                 "events.json"
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

  test "the canon events.yaml validates against events.json", %{schema: schema} do
    canon = YamlElixir.read_from_file!(@canon_path)
    assert :ok = ExJsonSchema.Validator.validate(schema, canon)
  end

  test "invalid config rejected — handler outside the Fleet.* namespace", %{schema: schema} do
    bad = %{"events" => %{"pod.allocated" => ["NotFleet.Handler"]}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  # Empty lists register events without routing metadata; direct subscribers can consume them.
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

  # A nonempty handler list is already invalid; this does not isolate trailing-dot validation.
  test "invalid config rejected — handler trailing dot", %{schema: schema} do
    bad = %{"events" => %{"pod.allocated" => ["Fleet.Spawner."]}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end
end
