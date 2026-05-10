defmodule Fleet.Credentials.Resolver do
  @moduledoc """
  Behaviour pour résolution env vars OAuth credentials role-based (LCARS schema v2.5).

  Une implémentation principale (`Fleet.Credentials`) lit le coffre
  `/var/lib/lcars/credentials/<role>/` et compose les ENV vars injectées
  au spawn pod (`CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, `CLAUDE_CODE_OAUTH_SCOPES`,
  optionnel `GIT_AUTHOR_*`).

  G24 invariant : JAMAIS `ANTHROPIC_API_KEY`, JAMAIS `--bare`.
  """

  @callback resolve_env(role :: String.t(), cap_profile :: Fleet.CapProfile.t()) ::
              {:ok, env_vars :: %{String.t() => String.t()}} | {:error, term()}
end
