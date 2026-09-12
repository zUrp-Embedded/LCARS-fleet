defmodule Fleet.Credentials.Gate do
  @moduledoc """
  Reads local Claude login-file shape for dashboard status and the spawn gate.
  Returns categories and path/expiry without token material. Token validity, expiry handling,
  scopes and plan eligibility are not checked here; the vendor/launcher handles authentication.
  """

  @doc """
  Reads <claude_dir>/.credentials.json. An OAuth map with a non-empty string accessToken
  gives logged_in (including whitespace-only strings); absent/invalid tokens give not_logged_in.
  File/JSON/OAuth-shape errors give unreadable with a categorized reason.

  expires_at_ms is the file's integer expiresAt value or nil, for display only. Expiry alone
  must not reject a token the launcher may refresh; refresh-token presence and success are not
  checked here. Never return the decoded JSON, access token or refresh token.
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

      _ ->
        %{status: :not_logged_in, path: creds_path}
    end
  end

  # Preserve integer epoch milliseconds; absent/null/other values remain unknown, not a fabricated date.
  defp expires_at_ms(oauth) do
    case Map.get(oauth, "expiresAt") do
      ms when is_integer(ms) -> ms
      _ -> nil
    end
  end

  @doc """
  Admits the local logged_in status, otherwise returns credentials_invalid with a categorized
  credentials_unreadable or not_logged_in reason and path. This is not a live token check.
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
