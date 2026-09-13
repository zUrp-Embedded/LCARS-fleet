defmodule Fleet.MCP.ToolInputSchemaTest do
  use ExUnit.Case, async: true

  # A half-renamed property can leave an impossible required key. Check root schemas
  # directly; the socket now enforces them, while direct handler calls bypass validation.
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
