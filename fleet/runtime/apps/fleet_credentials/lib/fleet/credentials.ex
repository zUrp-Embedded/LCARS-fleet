defmodule Fleet.Credentials do
  @moduledoc """
  Coffre creds + injection ENV vars au boot pod LCARS v2 (Ring 2).

  Module principal vendor-agnostic (sauf délégation `PlanValidator` au SDK).
  Résout les env vars OAuth role-based depuis le coffre
  `/var/lib/lcars/credentials/<role>/{oauth_refresh_token, oauth_access_token,
  oauth_scopes}` et compose les variables injectées au spawn pod.

  ## Voie auth canonique LCARS v2

    * `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` — universellement injectée
    * `CLAUDE_CODE_OAUTH_SCOPES` — universellement injectée

  Voies bannies (G24 invariants non-surchargeables) :

    * JAMAIS `ANTHROPIC_API_KEY` (raisons économiques 10-50$/h vs 90$/mois Max 5x)
    * JAMAIS `--bare` mode (5 incompatibilités ERRATUM #380/#381)
    * JAMAIS `claude setup-token` (idem)

  ## Cap-profile flags consommés

  Lecture string-keyed (cohérent `fleet_capprofile` PROMOTED L100) :

    * `cap_profile.spec["injects"]["useRoleCredentials"]` — bool, default `true`.
      Si `false` → fallback coffre `starfleet/`.
    * `cap_profile.spec["injects"]["gitconfig"]` — bool, default `false`.
      Si `true` → ajoute les 4 vars `GIT_AUTHOR_{NAME,EMAIL}` +
      `GIT_COMMITTER_{NAME,EMAIL}` template `LCARS-<role>` /
      `<role>@lcars.local`. Le delta `GIT_COMMITTER_*` (vs design note
      L98 qui ne nomme que `GIT_AUTHOR_*`) garantit que git pose
      l'identité committer cohérente avec auteur — sans ça, committer
      pointerait vers l'utilisateur système et l'auteur vers
      `LCARS-<role>`, créant une incohérence de provenance.
    * `cap_profile.spec["injects"]["forge_signing_allowed"]` — réservé
      D-04 E-006 dérogation (hors-MVP, lu sans effet ici).

  ## Exit codes

    * `{:ok, env_vars}` — résolution OK
    * `{:error, {:coffre_missing, role}}` — un fichier coffre absent
      (re-bootstrap user requis)
    * `{:error, {:coffre_file_unreadable, file, role, reason}}` —
      fichier coffre `file` (ex: `"oauth_refresh_token"`,
      `"oauth_scopes"`) présent mais illisible (`:eacces`, etc.)
  """

  @behaviour Fleet.Credentials.Resolver

  @oauth_refresh_token_env "CLAUDE_CODE_OAUTH_REFRESH_TOKEN"
  @oauth_scopes_env "CLAUDE_CODE_OAUTH_SCOPES"

  @doc """
  Résout les env vars OAuth pour un rôle donné.

  Lit le coffre sous `Fleet.Credentials.creds_root/0` puis compose le
  map `%{"CLAUDE_CODE_OAUTH_REFRESH_TOKEN" => ..., ...}` selon les
  flags `injects` du `cap_profile`.

  ## Exemples (doctest désactivé — IO disque)
  """
  @impl Fleet.Credentials.Resolver
  @spec resolve_env(String.t(), Fleet.CapProfile.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def resolve_env(role, %Fleet.CapProfile{spec: spec}) when is_binary(role) do
    injects = Map.get(spec, "injects", %{})
    use_role = Map.get(injects, "useRoleCredentials", true)
    effective_role = if use_role, do: role, else: "starfleet"

    with {:ok, refresh_token} <- read_coffre_file(effective_role, "oauth_refresh_token"),
         {:ok, scopes} <- read_coffre_file(effective_role, "oauth_scopes") do
      base = %{
        @oauth_refresh_token_env => String.trim(refresh_token),
        @oauth_scopes_env => String.trim(scopes)
      }

      {:ok, maybe_add_gitconfig(base, role, injects)}
    end
  end

  @doc """
  Renvoie le path absolu du fichier coffre `<creds_root>/<role>/<file>`.

  Public pour permettre aux sous-modules (`OAuthRefresher`,
  `Bootstrap.Extractor`) de partager la résolution de path sans
  dupliquer la racine.
  """
  @spec coffre_path(String.t(), String.t()) :: Path.t()
  def coffre_path(role, file) when is_binary(role) and is_binary(file) do
    Path.join([creds_root(), role, file])
  end

  @doc """
  Racine du coffre creds (config knob pour testabilité).

  Default : `/var/lib/lcars/credentials`. Surchargeable via
  `config :fleet_credentials, :creds_root, "/tmp/test-coffre"`.
  """
  @spec creds_root() :: Path.t()
  def creds_root do
    Application.get_env(:fleet_credentials, :creds_root, "/var/lib/lcars/credentials")
  end

  # ============================================================
  # Internals
  # ============================================================

  defp read_coffre_file(role, file) do
    path = coffre_path(role, file)

    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, {:coffre_missing, role}}

      {:error, reason} ->
        {:error, {:coffre_file_unreadable, file, role, reason}}
    end
  end

  defp maybe_add_gitconfig(env, role, injects) do
    if Map.get(injects, "gitconfig", false) do
      env
      |> Map.put("GIT_AUTHOR_NAME", "LCARS-#{role}")
      |> Map.put("GIT_AUTHOR_EMAIL", "#{role}@lcars.local")
      |> Map.put("GIT_COMMITTER_NAME", "LCARS-#{role}")
      |> Map.put("GIT_COMMITTER_EMAIL", "#{role}@lcars.local")
    else
      env
    end
  end
end
