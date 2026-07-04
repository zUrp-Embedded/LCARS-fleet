defmodule Fleet.Credentials.ForgeAuth do
  @moduledoc """
  Auth git **système-side** des ops forge privées (clone / fetch / ls-remote / push). Source UNIQUE :
  ce helper a un seul propriétaire ici plutôt qu'un duplicat byte-à-byte dans `Fleet.Workflow.Git` ET
  `Fleet.ProjectBootstrap.Phase.Clone` — le cycle compile `pipeline ⇄ bootstrap` interdit le partage
  entre eux. `fleet_credentials` est en-dessous des deux (dépendance commune) → bon propriétaire ; et
  le token forge EST un credential.

  ## Secret hors argv

  Le token (`%{url_prefix, token}` sous `:fleet_credentials, :forge_auth`, posé au boot depuis
  l'env/secret) est injecté via les variables d'**ENVIRONNEMENT** `GIT_CONFIG_COUNT` /
  `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` (git ≥ 2.31), **pas** sur l'argv. Passer le token via
  `-c http.<prefix>.extraheader=Authorization: token <T>` l'exposerait dans
  `/proc/<pid>/cmdline` — **world-readable** : un process d'un AUTRE humain sur l'hôte le lirait via
  `ps`. L'environ (`/proc/<pid>/environ`) est mode 0400 owner-only. Git applique la config-env
  exactement comme `-c` (vérifié git 2.43). Jamais persisté dans le `.git/config` du workspace → le
  pod hérite d'un remote SANS credential (barrière forge-aveugle).

  ## Usage

      System.cmd("git", ["clone", url, dst], env: Fleet.Credentials.ForgeAuth.git_env())

  Le secret vit alors dans l'environ du **process git enfant** (court-lived), jamais dans celui du
  BEAM (`System.cmd env:` ne touche que l'enfant). Non configuré (repo local `file://`, mirror) →
  `[]` → aucune variable posée, comportement inchangé.
  """

  # `GIT_TERMINAL_PROMPT=0` posé d'OFFICE dans la source unique de l'env git. Sans ça,
  # un token absent/expiré (ou un repo qui exige une auth qu'on n'a pas) fait que git OUVRE UN PROMPT
  # interactif (username/password) ; lancé par le BEAM SANS TTY, le prompt PEND indéfiniment → le
  # process git ne rend jamais → le GenServer appelant (Pod, Poller) reste figé sur `System.cmd`. La
  # borne `0` force git à ÉCHOUER tout de suite (rc≠0) au lieu de prompter — l'erreur typée remonte et
  # le wrapper borné (`Fleet.Credentials.Shell.run/2`) peut la tuer dans son délai. Posé même quand
  # `forge_auth` n'est PAS configuré (repo local `file://`) : c'est précisément le cas où l'absence de
  # credential déclencherait le prompt. Couvre TOUS les call-sites passant par `git_env()`.
  @git_no_prompt {"GIT_TERMINAL_PROMPT", "0"}

  @doc """
  Variables d'environnement de l'auth git système-side — `[{name, value}]` à passer tel quel à
  `System.cmd(env:)`. **Porte TOUJOURS `GIT_TERMINAL_PROMPT=0`** (borne anti-hang) ;
  ajoute l'extraheader d'auth forge SI `:fleet_credentials, :forge_auth` est présent et complet.
  Jamais `[]` (l'invariant anti-prompt est inconditionnel).
  """
  @spec git_env() :: [{String.t(), String.t()}]
  def git_env do
    case Application.get_env(:fleet_credentials, :forge_auth) do
      %{url_prefix: prefix, token: token}
      when is_binary(prefix) and is_binary(token) and prefix != "" and token != "" ->
        [
          @git_no_prompt,
          {"GIT_CONFIG_COUNT", "1"},
          {"GIT_CONFIG_KEY_0", "http.#{prefix}.extraheader"},
          {"GIT_CONFIG_VALUE_0", "Authorization: token #{token}"}
        ]

      _ ->
        [@git_no_prompt]
    end
  end
end
