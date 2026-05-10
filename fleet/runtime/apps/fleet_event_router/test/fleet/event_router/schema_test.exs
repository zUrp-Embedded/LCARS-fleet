defmodule Fleet.EventRouter.SchemaTest do
  use ExUnit.Case, async: true

  alias Fleet.EventRouter.Schema

  describe "schema/0" do
    test "retourne map type=object + 5 required" do
      s = Schema.schema()
      assert s["type"] == "object"
      assert "ts" in s["required"]
      assert "event_type" in s["required"]
      assert "node_id" in s["required"]
      assert "trace_id" in s["required"]
      assert "payload" in s["required"]
    end

    test "validation event valide :ok" do
      schema = ExJsonSchema.Schema.resolve(Schema.schema())

      event = %{
        "ts" => "2026-05-09T12:00:00Z",
        "event_type" => "pod.allocate",
        "node_id" => "node@host",
        "trace_id" => "abc1234567890def",
        "payload" => %{}
      }

      assert :ok = ExJsonSchema.Validator.validate(schema, event)
    end

    test "event manquant required → :error" do
      schema = ExJsonSchema.Schema.resolve(Schema.schema())
      event = %{"event_type" => "x"}
      assert {:error, _} = ExJsonSchema.Validator.validate(schema, event)
    end
  end
end
