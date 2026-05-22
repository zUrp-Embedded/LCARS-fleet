defmodule Fleet.Spawner.Pod.InitValidator do
  @moduledoc """
  Validation 9 champs critiques de la frame `init` NDJSON émise par
  claude -p au boot pod (F-INIT-VALIDATE handoff consultant SDK 100%).

  ## Champs requis

    * `tools` (list, non-vide)
    * `model` (string)
    * `permission_mode` (string)
    * `api_key_source` (string, `"oauth"` OU `"none"` — G24 invariant
      anti-`ANTHROPIC_API_KEY`. `"none"` est légitime quand claude
      ≥2.1.114 boote en mode OAuth env-vars
      `CLAUDE_CODE_OAUTH_TOKEN/REFRESH_TOKEN/SCOPES` — pas d'API key
      file-based, donc `apiKeySource: "none"` côté SDK. Defect #591.)
    * `cwd` (string)
    * `claude_code_version` (string)
    * `mcp_servers` (list)
    * `slash_commands` (list)
    * `agents` (list)

  ## Résilience camelCase ↔ snake_case (#591)

  claude 2.1.114 réel émet `apiKeySource` + `permissionMode` (camelCase),
  les autres champs en snake_case. Le validator accepte les 2 conventions
  via `@key_aliases` (drift défensif vendor SDK).

  ## Exit codes

    * `:ok` — validation OK
    * `{:error, :init_message_missing}` — message absent (nil)
    * `{:error, {:fields_missing, list_keys}}` — champs requis absents
    * `{:error, {:api_key_source_invalid, current}}` — autre que
      `"oauth"` ou `"none"`
  """

  @required_keys ~w(tools model permission_mode api_key_source cwd claude_code_version mcp_servers slash_commands agents)

  # Alias camelCase observés dans claude 2.1.114 réel (#591). Snake → camel.
  @key_aliases %{
    "api_key_source" => "apiKeySource",
    "permission_mode" => "permissionMode"
  }

  @valid_api_key_sources ["oauth", "none"]

  @spec validate(map() | nil, Fleet.CapProfile.t()) :: :ok | {:error, term()}
  def validate(nil, _cap_profile), do: {:error, :init_message_missing}

  def validate(init_message, _cap_profile) when is_map(init_message) do
    missing = Enum.reject(@required_keys, &has_field?(init_message, &1))

    cond do
      missing != [] ->
        {:error, {:fields_missing, missing}}

      get_field(init_message, "api_key_source") not in @valid_api_key_sources ->
        {:error, {:api_key_source_invalid, get_field(init_message, "api_key_source")}}

      true ->
        :ok
    end
  end

  # Présence : snake_case OU son alias camelCase.
  defp has_field?(msg, key) do
    Map.has_key?(msg, key) or
      (Map.has_key?(@key_aliases, key) and Map.has_key?(msg, Map.fetch!(@key_aliases, key)))
  end

  # Lecture : snake_case en priorité, fallback camelCase.
  defp get_field(msg, key) do
    case Map.get(msg, key) do
      nil -> Map.get(msg, Map.get(@key_aliases, key))
      v -> v
    end
  end
end
