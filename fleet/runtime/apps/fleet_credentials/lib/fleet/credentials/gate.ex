defmodule Fleet.Credentials.Gate do
  @moduledoc """
  Porte credentials au spawn-boundary : scope-coverage + plan payant.

  Entrée unique `validate/2`. Lit le claudeDir natif de l'humain UNE fois
  (`<claude_dir>/.credentials.json`, bloc `claudeAiOauth`), puis valide la
  couverture de scopes (`Fleet.Credentials.ScopeValidator`, par-rôle via les flags
  du cap-profile) ET le plan payant (`Fleet.Credentials.PlanValidator`). Le binaire
  claude impose déjà scope+plan (refus 401) ; ces gates font échouer TÔT — au
  spawn-boundary, côté runtime — au lieu du 1ᵉʳ appel API du pod. Tous les refus
  sont taggés `{:credentials_invalid, _}` pour les distinguer, au call-site
  (`Fleet.Spawner.Pod` au lancement), d'un échec d'auth-token.

  Transformateur pur : lecture fichier + délégation, sans état ni process. Le chemin
  du claudeDir est résolu par l'appelant (per-humain) et passé en argument — ce module
  ne fait QUE la validation, jamais la résolution du chemin.
  """

  @doc """
  Valide le `.credentials.json` d'un claudeDir humain contre un cap-profile.

  Lit `<claude_dir>/.credentials.json` (bloc `claudeAiOauth`), vérifie d'abord les
  scopes (par-rôle, dérivés des flags du cap-profile) puis le plan payant. Le premier
  échec court-circuite (`with`).

    * `claude_dir` — chemin du claudeDir de l'humain (résolu par l'appelant)
    * `cap_profile` — `%Fleet.CapProfile{}` ; ses flags pilotent les scopes requis

  Retour : `:ok` | `{:error, {:credentials_invalid, reason}}`.
  """
  @spec validate(Path.t(), Fleet.CapProfile.t()) ::
          :ok | {:error, {:credentials_invalid, term()}}
  def validate(claude_dir, cap_profile) do
    with {:ok, oauth} <- read_oauth_creds(claude_dir),
         :ok <- gate_scopes(oauth, cap_profile),
         :ok <- gate_plan(oauth) do
      :ok
    end
  end

  # SOURCE UNIQUE de lecture du creds natif `<claude_dir>/.credentials.json` : un seul
  # File.read + Jason.decode + extraction du bloc `claudeAiOauth`. `validate/2` (scope+plan)
  # consomme CE parse — source unique, pas de parsers driftables du même fichier.
  defp read_oauth_creds(claude_dir) do
    creds_path = Path.join(claude_dir, ".credentials.json")

    with {:ok, raw} <- File.read(creds_path),
         {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) <- Jason.decode(raw) do
      {:ok, oauth}
    else
      # Hygiène creds : la cause est CATÉGORISÉE, jamais le JSON décodé (qui porte
      # refreshToken/accessToken). `:malformed_json` (Jason) / `:no_oauth_block` (décodé sans bloc oauth
      # valide) / posix (File.read) — tous sûrs à propager et logger.
      {:error, %Jason.DecodeError{}} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, :malformed_json}}}

      {:ok, _decoded} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, :no_oauth_block}}}

      {:error, posix} ->
        {:error, {:credentials_invalid, {:credentials_unreadable, creds_path, posix}}}
    end
  end

  # ScopeValidator par-rôle : les scopes requis dépendent des flags du cap-profile
  # (bridge_enabled→user:profile, mcp_oauth→user:mcp_servers ; défaut = inference+sessions).
  defp gate_scopes(oauth, cap_profile) do
    scopes =
      case Map.get(oauth, "scopes") do
        l when is_list(l) -> l
        # certains formats portent les scopes en string whitespace-séparée (cf. ScopeValidator)
        s when is_binary(s) -> String.split(s)
        _ -> []
      end

    case Fleet.Credentials.ScopeValidator.validate(scopes, role_profile_flags(cap_profile)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:credentials_invalid, reason}}
    end
  end

  defp gate_plan(oauth) do
    case Map.get(oauth, "subscriptionType") do
      type when is_binary(type) ->
        case Fleet.Credentials.PlanValidator.validate(type) do
          :ok -> :ok
          {:error, reason} -> {:error, {:credentials_invalid, reason}}
        end

      _ ->
        {:error, {:credentials_invalid, :subscription_type_missing}}
    end
  end

  defp role_profile_flags(%Fleet.CapProfile{spec: spec}) do
    inv = Map.get(spec, "invocation", %{})
    inv = if is_map(inv), do: inv, else: %{}

    %{
      "bridge_enabled" => Map.get(inv, "bridge_enabled", false) == true,
      "mcp_oauth" => Map.get(inv, "mcp_oauth", false) == true
    }
  end
end
