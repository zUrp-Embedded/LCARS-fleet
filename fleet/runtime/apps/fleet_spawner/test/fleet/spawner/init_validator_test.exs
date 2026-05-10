defmodule Fleet.Spawner.Pod.InitValidatorTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.InitValidator

  defp valid_init do
    %{
      "tools" => ["Read"],
      "model" => "claude-sonnet-4-6",
      "permission_mode" => "default",
      "api_key_source" => "oauth",
      "cwd" => "/tmp/pod-x",
      "claude_code_version" => "2.1.138",
      "mcp_servers" => [],
      "slash_commands" => [],
      "agents" => []
    }
  end

  defp profile do
    %Fleet.CapProfile{
      api_version: "lcars/v2.5",
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer"},
      spec: %{}
    }
  end

  test "valid init message returns :ok" do
    assert :ok = InitValidator.validate(valid_init(), profile())
  end

  test "nil init message returns :init_message_missing" do
    assert {:error, :init_message_missing} = InitValidator.validate(nil, profile())
  end

  test "missing field returns :fields_missing with list" do
    init = Map.delete(valid_init(), "tools")
    assert {:error, {:fields_missing, ["tools"]}} = InitValidator.validate(init, profile())
  end

  test "multiple missing fields are listed" do
    init = valid_init() |> Map.delete("tools") |> Map.delete("model")

    assert {:error, {:fields_missing, missing}} = InitValidator.validate(init, profile())
    assert "tools" in missing
    assert "model" in missing
  end

  test "api_key_source != oauth returns :api_key_source_invalid" do
    init = Map.put(valid_init(), "api_key_source", "anthropic")

    assert {:error, {:api_key_source_invalid, "anthropic"}} =
             InitValidator.validate(init, profile())
  end

  test "api_key_source = none returns :api_key_source_invalid" do
    init = Map.put(valid_init(), "api_key_source", "none")
    assert {:error, {:api_key_source_invalid, "none"}} = InitValidator.validate(init, profile())
  end
end
