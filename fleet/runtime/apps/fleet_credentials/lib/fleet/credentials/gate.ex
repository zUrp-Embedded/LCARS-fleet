defmodule Fleet.Credentials.Gate do
  @moduledoc """
  Credentials gate at the spawn-boundary: scope-coverage + paid plan.

  Single entry point `validate/2`. Reads the human's native claudeDir ONCE
  (`<claude_dir>/.credentials.json`, `claudeAiOauth` block), then validates the
  scope coverage (`Fleet.Credentials.ScopeValidator`, per-role via the cap-profile
  flags) AND the paid plan (`Fleet.Credentials.PlanValidator`). The claude
  binary already enforces scope+plan (401 refusal); these gates fail EARLY — at the
  spawn-boundary, runtime-side — instead of at the pod's 1st API call. Every refusal
  is tagged `{:credentials_invalid, _}` so it can be distinguished, at the call-site
  (`Fleet.Spawner.Pod` at launch), from an auth-token failure.

  Pure transformer: file read + delegation, no state, no process. The claudeDir path
  is resolved by the caller (per-human) and passed as an argument — this module does
  ONLY the validation, never the path resolution.
  """

  @doc """
  Validates a human claudeDir's `.credentials.json` against a cap-profile.

  Reads `<claude_dir>/.credentials.json` (`claudeAiOauth` block), checks the scopes
  first (per-role, derived from the cap-profile flags) then the paid plan. The first
  failure short-circuits (`with`).

    * `claude_dir` — the human's claudeDir path (resolved by the caller)
    * `cap_profile` — `%Fleet.CapProfile{}`; its flags drive the required scopes

  Return: `:ok` | `{:error, {:credentials_invalid, reason}}`.
  """
  @spec validate(Path.t(), Fleet.CapProfile.t()) ::
          :ok | {:error, {:credentials_invalid, term()}}
  def validate(claude_dir, cap_profile) do
    with {:ok, oauth} <- read_oauth_creds(claude_dir),
         :ok <- gate_scopes(oauth, cap_profile),
         :ok <- gate_plan(oauth) do
      :ok
    end
  end

  # SINGLE SOURCE for reading the native creds `<claude_dir>/.credentials.json`: a single
  # File.read + Jason.decode + extraction of the `claudeAiOauth` block. `validate/2` (scope+plan)
  # consumes THIS parse — single source, no driftable parsers of the same file.
  defp read_oauth_creds(claude_dir) do
    creds_path = Path.join(claude_dir, ".credentials.json")

    with {:ok, raw} <- File.read(creds_path),
         {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) <- Jason.decode(raw) do
      {:ok, oauth}
    else
      # Creds hygiene: the cause is CATEGORIZED, never the decoded JSON (which carries
      # refreshToken/accessToken). `:malformed_json` (Jason) / `:no_oauth_block` (decoded without a valid
      # oauth block) / posix (File.read) — all safe to propagate and log.
      {:error, %Jason.DecodeError{}} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, :malformed_json}}}

      {:ok, _decoded} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, :no_oauth_block}}}

      {:error, posix} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, posix}}}
    end
  end

  # Per-role ScopeValidator: the required scopes depend on the cap-profile flags
  # (bridge_enabled→user:profile, mcp_oauth→user:mcp_servers; default = inference+sessions).
  defp gate_scopes(oauth, cap_profile) do
    scopes =
      case Map.get(oauth, "scopes") do
        l when is_list(l) -> l
        # some formats carry the scopes as a whitespace-separated string (cf. ScopeValidator)
        s when is_binary(s) -> String.split(s)
        _ -> []
      end

    case Fleet.Credentials.ScopeValidator.validate(scopes, role_profile_flags(cap_profile)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:credentials_invalid, reason}}
    end
  end

  defp gate_plan(oauth) do
    case Map.get(oauth, "subscriptionType") do
      type when is_binary(type) ->
        case Fleet.Credentials.PlanValidator.validate(type) do
          :ok -> :ok
          {:error, reason} -> {:error, {:credentials_invalid, reason}}
        end

      _ ->
        {:error, {:credentials_invalid, :subscription_type_missing}}
    end
  end

  defp role_profile_flags(%Fleet.CapProfile{spec: spec}) do
    inv = Map.get(spec, "invocation", %{})
    inv = if is_map(inv), do: inv, else: %{}

    %{
      "bridge_enabled" => Map.get(inv, "bridge_enabled", false) == true,
      "mcp_oauth" => Map.get(inv, "mcp_oauth", false) == true
    }
  end
end
