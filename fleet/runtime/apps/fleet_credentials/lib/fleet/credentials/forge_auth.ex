defmodule Fleet.Credentials.ForgeAuth do
  @moduledoc """
  Auth git **système-side** des ops forge privées (clone / fetch / ls-remote / push). Source UNIQUE
  (F095) : le helper était dupliqué byte-à-byte dans `Fleet.Pipeline.Git` ET
  `Fleet.ProjectBootstrap.Phase.Clone` — le cycle compile `pipeline ⇄ bootstrap` empêchait le
  partage. `fleet_credentials` est en-dessous des deux (dépendance commune) → bon propriétaire ; et
  le token forge EST un credential.

  ## Secret hors argv (F087)

  Le token (`%{url_prefix, token}` sous `:fleet_credentials, :forge_auth`, posé au boot depuis
  l'env/secret) est injecté via les variables d'**ENVIRONNEMENT** `GIT_CONFIG_COUNT` /
  `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` (git ≥ 2.31), **pas** sur l'argv. L'ancien
  `-c http.<prefix>.extraheader=Authorization: token <T>` exposait le token dans
  `/proc/<pid>/cmdline` — **world-readable** : un process d'un AUTRE humain sur l'hôte le lisait via
  `ps`. L'environ (`/proc/<pid>/environ`) est mode 0400 owner-only. Git applique la config-env
  exactement comme `-c` (vérifié git 2.43). Jamais persisté dans le `.git/config` du workspace → le
  pod hérite d'un remote SANS credential (barrière forge-aveugle, DN forge-state-machine §4).

  ## Usage

      System.cmd("git", ["clone", url, dst], env: Fleet.Credentials.ForgeAuth.git_env())

  Le secret vit alors dans l'environ du **process git enfant** (court-lived), jamais dans celui du
  BEAM (`System.cmd env:` ne touche que l'enfant). Non configuré (repo local `file://`, mirror) →
  `[]` → aucune variable posée, comportement inchangé.
  """

  @doc """
  Variables d'environnement injectant l'extraheader d'auth forge — `[{name, value}]` à passer tel
  quel à `System.cmd(env:)`. `[]` si `:fleet_credentials, :forge_auth` est absent ou incomplet.
  """
  @spec git_env() :: [{String.t(), String.t()}]
  def git_env do
    case Application.get_env(:fleet_credentials, :forge_auth) do
      %{url_prefix: prefix, token: token}
      when is_binary(prefix) and is_binary(token) and prefix != "" and token != "" ->
        [
          {"GIT_CONFIG_COUNT", "1"},
          {"GIT_CONFIG_KEY_0", "http.#{prefix}.extraheader"},
          {"GIT_CONFIG_VALUE_0", "Authorization: token #{token}"}
        ]

      _ ->
        []
    end
  end
end
