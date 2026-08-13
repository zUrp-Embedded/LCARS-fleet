defmodule Fleet.Credentials.ForgeAuth do
  @moduledoc """
  Single system-side git-auth source. Git 2.43 was verified to accept the token
  through `GIT_CONFIG_*` child-environment variables, keeping it out of argv and
  workspace config. Every result also disables interactive credential prompts.
  """

  # Anti-prompt is unconditional, including absent-auth local/test configurations.
  require Logger

  @git_no_prompt {"GIT_TERMINAL_PROMPT", "0"}

  @doc """
  Returns anti-prompt environment plus optional auth. DR-024 distinguishes an
  absent legitimate configuration from a present malformed credential.
  """
  @spec git_env_result() :: {:ok, [{String.t(), String.t()}]} | {:error, :forge_auth_malformed}
  def git_env_result do
    case Application.get_env(:lcars_fleet, :credentials_forge_auth) do
      nil ->
        {:ok, [@git_no_prompt]}

      %{url_prefix: prefix, token: token}
      when is_binary(prefix) and is_binary(token) and prefix != "" and token != "" ->
        if safe_prefix?(prefix) do
          {:ok,
           [
             @git_no_prompt,
             {"GIT_CONFIG_COUNT", "1"},
             {"GIT_CONFIG_KEY_0", "http.#{prefix}.extraheader"},
             {"GIT_CONFIG_VALUE_0", "Authorization: token #{token}"}
           ]}
        else
          # A newline/control char in `url_prefix` would inject a parasite git-config key. Refuse
          # (never `inspect` the value — it sits next to the token). LOUD, and typed as malformed.
          Logger.error(
            "ForgeAuth: :forge_auth url_prefix carries a newline/control char — REFUSED " <>
              "(auth-required git ops fail loud). Fix the forge config."
          )

          {:error, :forge_auth_malformed}
        end

      _other ->
        # PRESENT but malformed (empty/missing url_prefix or token, wrong shape): typed error, not a silent
        # UNAUTHENTICATED op that masks the broken credential as a later 403/404 (MINE-CRED-01).
        Logger.error(
          "ForgeAuth: :forge_auth is PRESENT but malformed (empty/missing url_prefix or token) — REFUSED " <>
            "(auth-required git ops fail loud). Fix the forge config."
        )

        {:error, :forge_auth_malformed}
    end
  end

  @doc """
  Environment variables for the system-side git auth — `[{name, value}]` to pass as-is to
  `System.cmd(env:)`. **ALWAYS carries `GIT_TERMINAL_PROMPT=0`** (anti-hang bound); adds the forge auth
  extraheader IF `:forge_auth` is present and complete. Never `[]` (the anti-prompt invariant is unconditional).

  For OPTIONAL-auth / local git ONLY. On a present-but-MALFORMED config it degrades to `[@git_no_prompt]`
  (the error is logged LOUD by `git_env_result/0`). **Auth-REQUIRED paths MUST use `git_env_result/0`**
  to fail-loud on a broken credential instead of running unauthenticated (DR-024).
  """
  @spec git_env() :: [{String.t(), String.t()}]
  def git_env do
    case git_env_result() do
      {:ok, env} -> env
      {:error, :forge_auth_malformed} -> [@git_no_prompt]
    end
  end

  # `url_prefix` is interpolated into the git-config key `http.<prefix>.extraheader`: a control char
  # (esp. newline) would inject a parasite config line. NOT the full URL authority — a guardrail.
  defp safe_prefix?(prefix), do: not String.match?(prefix, ~r/[\x00-\x1F\x7F]/)
end
