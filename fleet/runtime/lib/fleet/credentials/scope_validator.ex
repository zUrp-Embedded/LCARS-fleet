defmodule Fleet.Credentials.ScopeValidator do
  @moduledoc """
  Scope-coverage gate `oauth_scopes ⊇ role_required_scopes`.

  Wired at **spawn** via `Fleet.Credentials.Gate.validate/2` (called by
  `Fleet.Spawner.Pod` at launch): reads the scopes from the human's `.credentials.json` (bound native, no copy) and refuses the
  spawn (`{:credentials_invalid, {:insufficient_scopes, …}}`) if insufficient. Preflight defense in
  depth (the claude binary also enforces the scopes via 401, but we fail
  early and clear on the runtime side). No vault nor `setup-credentials.sh`: the human's claudeDir
  is bound directly, there is no `/var/lib/lcars/credentials` vault.

  ## Scope profiles

    * `default` — operational minimum (`user:inference`,
      `user:sessions:claude_code`)
    * `bridge_enabled` — adds `user:profile` (Bridge / Remote
      Control opt-in, out-of-MVP but the profile is ready)
    * `mcp_oauth` — adds `user:mcp_servers` (MCP OAuth
      Anthropic-mediated)

  Combinable: a cap-profile can enable several flags, the union
  of the required scopes is computed.

  ## Exit codes

    * `:ok` — scopes sufficient (`required \\\\ oauth_scopes` empty)
    * `{:error, {:insufficient_scopes, missing}}` — list of the
      missing scopes (order preserved for human reporting)
  """

  @scopes_default ["user:inference", "user:sessions:claude_code"]
  @scopes_bridge ["user:profile"]
  @scopes_mcp ["user:mcp_servers"]

  @doc """
  Validates that a list of OAuth scopes covers the role's requirements.

  ## Inputs

    * `oauth_scopes` — list read from the human's `.credentials.json`
      (string-split on whitespace on the caller side)
    * `role_profile_flags` — map of the flags enabled on the cap-profile,
      e.g. `%{"bridge_enabled" => true}`. Any key not listed
      above is silently ignored.

  ## Examples

      iex> Fleet.Credentials.ScopeValidator.validate(
      ...>   ["user:inference", "user:sessions:claude_code"],
      ...>   %{}
      ...> )
      :ok

      iex> Fleet.Credentials.ScopeValidator.validate(
      ...>   ["user:inference"],
      ...>   %{}
      ...> )
      {:error, {:insufficient_scopes, ["user:sessions:claude_code"]}}
  """
  @spec validate(term(), term()) ::
          :ok | {:error, {:insufficient_scopes, [String.t()]} | {:invalid_scope_args, term()}}
  def validate(oauth_scopes, role_profile_flags)
      when is_list(oauth_scopes) and is_map(role_profile_flags) do
    required = compute_required(role_profile_flags)
    missing = required -- oauth_scopes

    if missing == [], do: :ok, else: {:error, {:insufficient_scopes, missing}}
  end

  # Total (R1-36): malformed args (oauth_scopes not a list, role_profile_flags not a map) → typed refusal,
  # not a FunctionClauseError. A caller (Gate) normalizes upstream, but the validator stands total on its own.
  def validate(oauth_scopes, role_profile_flags),
    do: {:error, {:invalid_scope_args, {oauth_scopes, role_profile_flags}}}

  @doc """
  List of the scopes required for a given set of flags.

  Pure utility (no IO), exposed for the shell-side pre-flight
  check and runtime documentation.
  """
  @spec compute_required(map()) :: [String.t()]
  def compute_required(role_profile_flags) when is_map(role_profile_flags) do
    base = @scopes_default

    base =
      if Map.get(role_profile_flags, "bridge_enabled", false),
        do: base ++ @scopes_bridge,
        else: base

    base = if Map.get(role_profile_flags, "mcp_oauth", false), do: base ++ @scopes_mcp, else: base
    base
  end
end
