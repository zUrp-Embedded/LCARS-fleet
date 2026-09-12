defmodule Fleet.Credentials.ForgeAuth do
  @moduledoc """
  Builds system-side git authentication via GIT_CONFIG_* child-environment variables,
  keeping the header out of argv and workspace config. Successful environment results disable
  Git terminal credential prompts; the local test checks that Git reads the header from env.
  """

  require Logger

  @git_no_prompt {"GIT_TERMINAL_PROMPT", "0"}

  # Configured-but-unavailable auth must not look like a legitimate no-auth configuration.
  defp resolve(prefix, account) do
    case Fleet.Credentials.Authority.token(account) do
      {:ok, token} ->
        {:ok, extraheader_env(prefix, "token " <> token)}

      {:error, cause} ->
        Logger.error(
          "ForgeAuth: aucun jeton pour le compte #{inspect(account)} — #{inspect(cause)}. " <>
            "Toute operation git authentifiee echouera, et ce n'est PAS un probleme de git."
        )

        {:error, :forge_auth_unavailable}
    end
  end

  @doc """
  Returns the non-empty account from credentials_forge_auth, otherwise nil.
  No default identity is invented for tooling or deployments without forge auth.
  This does not validate the rest of the configuration.
  """
  @spec account() :: String.t() | nil
  def account do
    case Application.get_env(:lcars_fleet, :credentials_forge_auth) do
      %{account: account} when is_binary(account) and account != "" -> account
      _ -> nil
    end
  end

  @doc """
  Requests an account token through the internal Authority client without caching.
  Cross-domain HTTP/publish callers use this facade so transport knowledge stays here.
  Rechecking issuance does not invalidate credentials already returned to a caller.
  """
  @spec token_for(String.t()) ::
          {:ok, String.t()} | {:error, Fleet.Credentials.Authority.cause()}
  defdelegate token_for(account), to: Fleet.Credentials.Authority, as: :token

  @doc """
  Returns terminal anti-prompt env plus optional auth from credentials_forge_auth.
  Nil config succeeds without a header; malformed config and unavailable account tokens
  return distinct errors. An :ok result alone does not prove credentials were supplied.
  """
  @spec git_env_result() ::
          {:ok, [{String.t(), String.t()}]}
          | {:error, :forge_auth_malformed | :forge_auth_unavailable}
  def git_env_result do
    case Application.get_env(:lcars_fleet, :credentials_forge_auth) do
      nil ->
        {:ok, [@git_no_prompt]}

      # Store account identity in config; request the secret when constructing the operation's env.
      %{url_prefix: prefix, account: account}
      when is_binary(prefix) and is_binary(account) and prefix != "" and account != "" ->
        if safe_prefix?(prefix) do
          resolve(prefix, account)
        else
          # Reject controls before interpolating a git-config key; do not log the supplied value.
          Logger.error(
            "ForgeAuth: :forge_auth url_prefix carries a newline/control char — REFUSED " <>
              "(auth-required git ops fail loud). Fix the forge config."
          )

          {:error, :forge_auth_malformed}
        end

      _other ->
        Logger.error(
          "ForgeAuth: :forge_auth is PRESENT but malformed (empty/missing url_prefix or account) — REFUSED " <>
            "(auth-required git ops fail loud). Fix the forge config."
        )

        {:error, :forge_auth_malformed}
    end
  end

  @doc """
  Returns env pairs for System.cmd, always including GIT_TERMINAL_PROMPT=0 when it returns.
  Optional-auth/local use only: malformed configuration or unavailable auth degrades to
  anti-prompt env after logging. Auth-required callers must use git_env_result/0 to preserve
  those errors and ensure configuration is present; inherited Git auth is not cleared here.
  """
  @spec git_env() :: [{String.t(), String.t()}]
  def git_env do
    # Keep both typed failures covered by this optional-auth adapter.
    case git_env_result() do
      {:ok, env} ->
        env

      {:error, cause} when cause in [:forge_auth_malformed, :forge_auth_unavailable] ->
        [@git_no_prompt]
    end
  end

  @doc """
  Builds child env carrying a complete Authorization value (for example token or Basic)
  for one Git URL prefix. Reused by internal forge operations and private repository import.
  Environment avoids argv/URL disclosure but remains secret-bearing process data.
  This builder validates neither argument and replaces GIT_CONFIG_COUNT with one; callers
  must validate the prefix/credential and account for any existing config environment.
  """
  @spec extraheader_env(String.t(), String.t()) :: [{String.t(), String.t()}]
  def extraheader_env(prefix, credential) when is_binary(prefix) and is_binary(credential) do
    [
      @git_no_prompt,
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "http.#{prefix}.extraheader"},
      {"GIT_CONFIG_VALUE_0", "Authorization: #{credential}"}
    ]
  end

  @doc """
  Rejects ASCII controls in a prefix destined for a git-config key. This is not URL validation
  and accepts an empty string; extraheader_env/2 does not call it automatically.
  """
  @spec safe_prefix?(String.t()) :: boolean()
  def safe_prefix?(prefix), do: not String.match?(prefix, ~r/[\x00-\x1F\x7F]/)
end
