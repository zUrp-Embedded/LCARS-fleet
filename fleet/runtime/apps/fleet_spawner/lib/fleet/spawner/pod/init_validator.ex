defmodule Fleet.Spawner.Pod.InitValidator do
  @moduledoc """
  Validation 9 champs critiques de la frame `init` NDJSON émise par
  claude -p au boot pod (F-INIT-VALIDATE handoff consultant SDK 100%).

  ## Champs requis

    * `tools` (list, non-vide)
    * `model` (string)
    * `permission_mode` (string)
    * `api_key_source` (string, doit être `"oauth"` — G24 invariant
      anti-`ANTHROPIC_API_KEY`)
    * `cwd` (string)
    * `claude_code_version` (string)
    * `mcp_servers` (list)
    * `slash_commands` (list)
    * `agents` (list)

  ## Exit codes

    * `:ok` — validation OK
    * `{:error, :init_message_missing}` — message absent (nil)
    * `{:error, {:fields_missing, list_keys}}` — champs requis absents
    * `{:error, {:api_key_source_invalid, current}}` — autre que `"oauth"`
  """

  @required_keys ~w(tools model permission_mode api_key_source cwd claude_code_version mcp_servers slash_commands agents)

  @spec validate(map() | nil, Fleet.CapProfile.t()) :: :ok | {:error, term()}
  def validate(nil, _cap_profile), do: {:error, :init_message_missing}

  def validate(init_message, _cap_profile) when is_map(init_message) do
    missing = Enum.reject(@required_keys, &Map.has_key?(init_message, &1))

    cond do
      missing != [] ->
        {:error, {:fields_missing, missing}}

      Map.get(init_message, "api_key_source") != "oauth" ->
        {:error, {:api_key_source_invalid, Map.get(init_message, "api_key_source")}}

      true ->
        :ok
    end
  end
end
