defmodule Fleet.Credentials.ForgeAuth do
  @moduledoc """
  Single system-side git-auth source. Git 2.43 accepts the token through `GIT_CONFIG_*`
  child-environment variables (verified against that version), which keeps it out of argv and out of
  the workspace config. Every result also disables interactive credential prompts.
  """

  # Anti-prompt is unconditional, including absent-auth local/test configurations.
  require Logger

  @git_no_prompt {"GIT_TERMINAL_PROMPT", "0"}

  # ⚠ FAIL-CLOSED, ET DISTINCT D'UNE CONFIGURATION ABSENTE. `nil` en config veut dire « cette boite
  # ne pousse pas », et c'est legitime (un banc, un mode outil). Un compte configure dont le service
  # ne rend pas le jeton est autre chose : la boite CROIT pouvoir pousser et ne le peut pas. Les
  # confondre rendrait un `git` sans auth, dont l'echec accuse git.
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
  Le compte de forge SOUS LEQUEL CETTE BOITE AGIT, ou `nil` si elle n'en a pas.

  Il vit ici et pas dans chaque appelant parce que deux gestes le demandent — `git push` par
  `git_env/0`, et l'outil de POD `project_publish`, qui doit materialiser un jeton pour un rail en
  shell. Deux facons de trouver « le compte du systeme » divergent, et celle qu'on lit n'est jamais
  celle qu'on a corrigee.

  `nil` est un etat LEGITIME : une boite en mode outil, un banc sans forge. L'appelant en fait ce
  qu'il veut ; ce module ne devine pas de nom par defaut.
  """
  @spec account() :: String.t() | nil
  def account do
    case Application.get_env(:lcars_fleet, :credentials_forge_auth) do
      %{account: account} when is_binary(account) and account != "" -> account
      _ -> nil
    end
  end

  @doc """
  Le jeton de forge d'un COMPTE, demandé au service d'autorité — ou une cause nommée.

  ## Pourquoi il passe par ici

  `Fleet.Credentials.Authority` est INTERNE au domaine, et doit le rester : c'est le client d'une
  socket, pas une API. Deux appelants hors domaine ont pourtant besoin d'un jeton pour un compte —
  le transport du client de forge (chaque verbe HTTP) et l'outil de POD `project_publish`, qui doit
  matérialiser un fichier pour un rail en shell.

  Leur donner le client direct multiplierait les endroits qui savent qu'une socket existe. Ce module
  est déjà la porte de l'auth système ; il porte donc aussi cette question-là, et le jour où la
  résolution change — un cache, un second service, une autre voie — un seul endroit le sait.

  ⚠ AUCUN CACHE, ET C'EST LA PROPRIÉTÉ ACHETÉE. Un jeton gardé ici lui rendrait une péremption
  INFINIE : la révocation ne mordrait plus qu'au redémarrage du nœud.
  """
  @spec token_for(String.t()) ::
          {:ok, String.t()} | {:error, Fleet.Credentials.Authority.cause()}
  defdelegate token_for(account), to: Fleet.Credentials.Authority, as: :token

  @doc """
  Returns anti-prompt environment plus optional auth. DR-024 distinguishes an
  absent legitimate configuration from a present malformed credential.
  """
  @spec git_env_result() ::
          {:ok, [{String.t(), String.t()}]}
          | {:error, :forge_auth_malformed | :forge_auth_unavailable}
  def git_env_result do
    case Application.get_env(:lcars_fleet, :credentials_forge_auth) do
      nil ->
        {:ok, [@git_no_prompt]}

      # ⚠ LA CONFIG PORTE LE COMPTE, JAMAIS LE JETON. Le jeton se demande au service d'autorite AU
      # MOMENT DE POUSSER : la revocation mord au geste suivant, et l'application env ne porte aucun
      # secret qu'une porte de dump pourrait publier.
      %{url_prefix: prefix, account: account}
      when is_binary(prefix) and is_binary(account) and prefix != "" and account != "" ->
        if safe_prefix?(prefix) do
          resolve(prefix, account)
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
        # PRESENT but malformed (empty/missing url_prefix or ACCOUNT, wrong shape): typed error, not a
        # silent UNAUTHENTICATED op that masks the broken credential as a later 403/404 (MINE-CRED-01).
        # The message names `account`, never `token`: the config carries no secret, and a message
        # that sends the reader to look for one is a false diagnosis.
        Logger.error(
          "ForgeAuth: :forge_auth is PRESENT but malformed (empty/missing url_prefix or account) — REFUSED " <>
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
    # ⚠ LES DEUX CAUSES SE COMPORTENT PAREIL ICI, ET ELLES RESTENT DISTINCTES EN AMONT. Cette porte
    # ne rend qu'un environnement : sans auth, git echoue bruyamment, ce qui est le bon repli pour
    # les deux. Mais `git_env_result/0` les separe, parce que les gestes different — un credential
    # MALFORME se corrige dans la config, un credential INDISPONIBLE veut savoir si le service
    # d'autorite repond.
    #
    # ⚠ ET CE `case` ETAIT EXHAUSTIF SUR UNE SEULE CAUSE. Ajouter la seconde sans l'ajouter ici
    # aurait leve un `CaseClauseError` — un crash a la place d'un echec nomme, sur le chemin exact
    # ou la boite vient de perdre son identite de forge.
    case git_env_result() do
      {:ok, env} ->
        env

      {:error, cause} when cause in [:forge_auth_malformed, :forge_auth_unavailable] ->
        [@git_no_prompt]
    end
  end

  @doc """
  Env carrying an HTTP `Authorization` header to git, for one url prefix — **never argv**.

  L'UNIQUE FACON DONT CE DEPOT DONNE UN SECRET A GIT, et le point est la surface : `GIT_CONFIG_*`
  passe par l'environnement du processus, lisible par le seul propriétaire via `/proc/<pid>/environ`,
  alors qu'un token pose en argv (userinfo d'URL comprise) est visible de tout le monde dans `ps`
  pendant toute la duree de l'operation — et ressort dans les messages d'erreur de git, qui citent
  l'URL.

  Extraite ici parce qu'elle avait DEUX utilisateurs et une seule implementation : la forge interne
  (`git_env_result/0`, juste au-dessus) et l'import d'un depot externe prive
  (`Fleet.Project.Onboard`), qui lui posait le token en userinfo. Un mecanisme de credential
  duplique est un mecanisme dont une copie finit par diverger.

  `credential` est la valeur d'en-tete complete (`"token abc"`, `"Basic <b64>"`) : cette fonction ne
  choisit pas le schema d'authentification, elle choisit le CANAL.
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
  `url_prefix` guardrail, exported with the env builder it protects.

  Un caractere de controle (surtout un saut de ligne) interpole dans la cle git-config
  `http.<prefix>.extraheader` injecterait une ligne de config parasite. Ce n'est PAS l'autorite
  complete de l'URL — c'est un garde-fou, et il voyage avec la fonction qu'il garde : un appelant qui
  construit son prefixe depuis une URL d'operateur doit pouvoir le poser sans le reecrire.
  """
  @spec safe_prefix?(String.t()) :: boolean()
  def safe_prefix?(prefix), do: not String.match?(prefix, ~r/[\x00-\x1F\x7F]/)
end
