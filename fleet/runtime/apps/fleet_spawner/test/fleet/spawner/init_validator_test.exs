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

  # #591 — claude 2.1.114 réel émet `apiKeySource: "none"` en mode OAuth
  # env-vars (CLAUDE_CODE_OAUTH_TOKEN/REFRESH_TOKEN/SCOPES). Pas une erreur.
  test "api_key_source = none is valid (OAuth env-vars mode #591)" do
    init = Map.put(valid_init(), "api_key_source", "none")
    assert :ok = InitValidator.validate(init, profile())
  end

  test "api_key_source unknown value still invalid" do
    init = Map.put(valid_init(), "api_key_source", "bedrock")

    assert {:error, {:api_key_source_invalid, "bedrock"}} =
             InitValidator.validate(init, profile())
  end

  # #591 — claude 2.1.114 réel émet `apiKeySource` + `permissionMode`
  # (camelCase). Les autres champs restent snake_case. Validator accepte
  # les 2 conventions sur ces 2 keys (résilience drift vendor SDK).
  test "camelCase apiKeySource accepted (claude 2.1.114 real)" do
    init =
      valid_init()
      |> Map.delete("api_key_source")
      |> Map.put("apiKeySource", "none")

    assert :ok = InitValidator.validate(init, profile())
  end

  test "camelCase permissionMode accepted (claude 2.1.114 real)" do
    init =
      valid_init()
      |> Map.delete("permission_mode")
      |> Map.put("permissionMode", "default")

    assert :ok = InitValidator.validate(init, profile())
  end

  test "real claude 2.1.114 init frame (mixed snake + camel + none)" do
    # Reproduction fidèle du NDJSON observé pod-6ac28b91 (#591).
    init = %{
      "tools" => ["Bash", "Read", "Write"],
      "model" => "claude-sonnet-4-6",
      "permissionMode" => "default",
      "apiKeySource" => "none",
      "cwd" => "/var/lib/lcars/pods/pod-x",
      "claude_code_version" => "2.1.114",
      "mcp_servers" => [],
      "slash_commands" => [],
      "agents" => []
    }

    assert :ok = InitValidator.validate(init, profile())
  end
end
