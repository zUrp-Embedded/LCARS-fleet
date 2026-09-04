defmodule Fleet.MCP.ToolInputSchemaTest do
  use ExUnit.Case, async: true

  # 2026-09-04 — NOBODY on the server side validates a call against its `input_schema`: ExMCP checks
  # prompt arguments only, and the handlers read their keys by hand. `required` is read by the
  # CLIENT that builds the call. So a `required` naming a key `properties` does not describe is an
  # obligation the agent cannot meet — the realistic drift is a half-done rename (the property
  # moves, the list does not), which no compiler and no wall sees. Measured on the 32 tools the day
  # this test was written: zero drift. This pins it.
  test "every deftool's `required` names only keys its `properties` describe" do
    tools = Fleet.MCP.PodTools.get_tools()
    assert map_size(tools) >= 12, "population guard: a deftool reshape emptied the tool set"

    drift =
      for {name, tool} <- tools,
          schema = tool[:input_schema] || tool["input_schema"] || %{},
          props = schema |> Map.get("properties", %{}) |> Map.keys(),
          extra = Map.get(schema, "required", []) -- props,
          extra != [] do
        {name, extra}
      end

    assert drift == [],
           "required keys with no property behind them (rename half done?): #{inspect(drift)}"
  end

  test "every deftool schema is an object with a `properties` map, the shape the CLI parses" do
    for {name, tool} <- Fleet.MCP.PodTools.get_tools() do
      schema = tool[:input_schema] || tool["input_schema"] || %{}
      assert schema["type"] == "object", "#{name}: input_schema.type must be \"object\""
      assert is_map(schema["properties"]), "#{name}: input_schema.properties must be a map"
    end
  end
end
