defmodule Fleet.Credentials.Gate do
  @moduledoc """
  Single reader of the human Claude login file. `status/1` returns categorized,
  dashboard-safe facts without token material; `validate/1` derives the spawn gate.
  Scope and plan validity remain vendor-enforced.
  """

  # BL-6-09
  @doc """
  Structured login status of `<claude_dir>/.credentials.json` — dashboard-safe (categorized
  facts + path, NEVER the decoded JSON: it carries accessToken/refreshToken).

    * `%{status: :logged_in, path: p, expires_at_ms: ms | nil}` — usable login token present.
      `expires_at_ms` (epoch ms, as the file states it) is DATA for a dashboard countdown, not a
      verdict: an expired access token with a refresh token still refreshes at launch
      (cf. `bin/bwrap_launch.sh`) — expiry alone is never reported as logged-out.
    * `%{status: :not_logged_in, path: p}` — oauth block present, no usable accessToken.
    * `%{status: :unreadable, path: p, reason: :malformed_json | :no_oauth_block | posix}` —
      the file cannot answer the question (absent, undecodable, or foreign shape).
  """
  @spec status(Path.t()) ::
          %{status: :logged_in, path: Path.t(), expires_at_ms: integer() | nil}
          | %{status: :not_logged_in, path: Path.t()}
          | %{status: :unreadable, path: Path.t(), reason: atom()}
  def status(claude_dir) do
    creds_path = Path.join(claude_dir, ".credentials.json")

    with {:ok, raw} <- File.read(creds_path),
         {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) <- Jason.decode(raw),
         token when is_binary(token) and token != "" <- Map.get(oauth, "accessToken") do
      %{status: :logged_in, path: creds_path, expires_at_ms: expires_at_ms(oauth)}
    else
      {:error, %Jason.DecodeError{}} ->
        %{status: :unreadable, path: creds_path, reason: :malformed_json}

      # Decoded, but no `claudeAiOauth` map (a different/partial creds file).
      {:ok, _decoded} ->
        %{status: :unreadable, path: creds_path, reason: :no_oauth_block}

      {:error, posix} when is_atom(posix) ->
        %{status: :unreadable, path: creds_path, reason: posix}

      # oauth block present but no usable accessToken → not logged in.
      _ ->
        %{status: :not_logged_in, path: creds_path}
    end
  end

  # `expiresAt` is epoch MILLISECONDS in the native file; `null` is a legitimate durable login
  # (cf. the launch-side refresh rationale) — reported as nil, never fabricated into a date.
  defp expires_at_ms(oauth) do
    case Map.get(oauth, "expiresAt") do
      ms when is_integer(ms) -> ms
      _ -> nil
    end
  end

  @doc """
  Confirms the human is logged in — the SPAWN gate, derived from `status/1` (one reader).

    * `claude_dir` — the human's claudeDir path (resolved by the caller)

  Return: `:ok` | `{:error, {:credentials_invalid, reason}}`. The reason is CATEGORIZED, never the
  decoded JSON: `{:credentials_unreadable, path, why}` / `{:not_logged_in, path}` — all safe to
  propagate, log, and surface.
  """
  @spec validate(Path.t()) :: :ok | {:error, {:credentials_invalid, term()}}
  def validate(claude_dir) do
    case status(claude_dir) do
      %{status: :logged_in} ->
        :ok

      %{status: :not_logged_in, path: path} ->
        {:error, {:credentials_invalid, {:not_logged_in, path}}}

      %{status: :unreadable, path: path, reason: reason} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, path, reason}}}
    end
  end
end
