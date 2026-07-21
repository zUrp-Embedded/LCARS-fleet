defmodule Fleet.Credentials.Gate do
  @moduledoc """
  Login-validity check at the spawn-boundary: is the human logged in to Claude Code?

  Reads the human's native `<claude_dir>/.credentials.json` (`claudeAiOauth` block) and confirms a
  usable login token is present. The result is tagged `{:credentials_invalid, _}` so the call-site
  (`Fleet.Spawner.Pod` at launch) distinguishes a login problem from other failures — and a future
  dashboard can report the login status.

  NUKED 2026-07-20 (user decision): the former scope-coverage + paid-plan gates
  (`ScopeValidator`/`PlanValidator`) DUPLICATED the claude binary's own enforcement (401 on
  insufficient scope/plan) for a marginal early-error. In practice a valid `claude /login` always
  carries the standard scope bundle — the scope check verified a condition that never occurs, and
  the plan check was literally "did you pay", already enforced by the binary. Only the honest
  "is there a login?" survives.

  Backlog: a proper shared AUTH HELPER (token read / refresh / status report) is still to be built.

  Pure transformer: file read + decode, no state, no process. The claudeDir is resolved by the
  caller (per-human) and passed as an argument.

  **Last revised**: 2026-07-21
  """

  @doc """
  Confirms the human is logged in: `<claude_dir>/.credentials.json` exists, decodes, and carries a
  `claudeAiOauth` block with a non-empty `accessToken`.

    * `claude_dir` — the human's claudeDir path (resolved by the caller)

  Return: `:ok` | `{:error, {:credentials_invalid, reason}}`. The reason is CATEGORIZED, never the
  decoded JSON (which carries refreshToken/accessToken): `:malformed_json` / `:no_oauth_block` /
  `:not_logged_in` / posix — all safe to propagate, log, and surface to a dashboard.
  """
  @spec validate(Path.t()) :: :ok | {:error, {:credentials_invalid, term()}}
  def validate(claude_dir) do
    creds_path = Path.join(claude_dir, ".credentials.json")

    with {:ok, raw} <- File.read(creds_path),
         {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) <- Jason.decode(raw),
         token when is_binary(token) and token != "" <- Map.get(oauth, "accessToken") do
      :ok
    else
      {:error, %Jason.DecodeError{}} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, :malformed_json}}}

      # Decoded, but no `claudeAiOauth` map (a different/partial creds file).
      {:ok, _decoded} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, :no_oauth_block}}}

      {:error, posix} when is_atom(posix) ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, posix}}}

      # oauth block present but no usable accessToken → not logged in.
      _ ->
        {:error, {:credentials_invalid, {:not_logged_in, creds_path}}}
    end
  end
end
