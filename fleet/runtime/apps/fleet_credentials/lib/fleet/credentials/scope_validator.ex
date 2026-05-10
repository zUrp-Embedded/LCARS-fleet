defmodule Fleet.Credentials.ScopeValidator do
  @moduledoc """
  Gate scope-coverage `oauth_scopes ⊇ scopes_requis_role`.

  Appelé en pré-flight install (`bin/setup-credentials.sh`) **et** au
  boot pod (`Fleet.Spawner` phase ALLOCATE). Défense en profondeur :
  refus install si scopes insuffisants côté user, refus spawn si
  drift coffre côté runtime.

  ## Profils de scopes

    * `default` — minimum opérationnel (`user:inference`,
      `user:sessions:claude_code`)
    * `bridge_enabled` — ajoute `user:profile` (D-03 Bridge / Remote
      Control opt-in, hors-MVP mais profil prêt)
    * `mcp_oauth` — ajoute `user:mcp_servers` (MCP OAuth
      Anthropic-mediated)

  Combinable : un cap-profile peut activer plusieurs flags, l'union
  des scopes requis est calculée.

  ## Exit codes

    * `:ok` — scopes suffisants (`required \\\\ oauth_scopes` vide)
    * `{:error, {:insufficient_scopes, missing}}` — liste des scopes
      manquants (ordre conservé pour rapport humain)
  """

  @scopes_default ["user:inference", "user:sessions:claude_code"]
  @scopes_bridge ["user:profile"]
  @scopes_mcp ["user:mcp_servers"]

  @doc """
  Valide qu'une liste de scopes OAuth couvre les requis du rôle.

  ## Inputs

    * `oauth_scopes` — liste lue du coffre `oauth_scopes`
      (string-split sur whitespace côté caller)
    * `role_profile_flags` — map des flags activés sur le cap-profile,
      par ex. `%{"bridge_enabled" => true}`. Toute clé non listée
      ci-dessus est ignorée silencieusement.

  ## Exemples

      iex> Fleet.Credentials.ScopeValidator.validate(
      ...>   ["user:inference", "user:sessions:claude_code"],
      ...>   %{}
      ...> )
      :ok

      iex> Fleet.Credentials.ScopeValidator.validate(
      ...>   ["user:inference"],
      ...>   %{}
      ...> )
      {:error, {:insufficient_scopes, ["user:sessions:claude_code"]}}
  """
  @spec validate([String.t()], map()) ::
          :ok | {:error, {:insufficient_scopes, [String.t()]}}
  def validate(oauth_scopes, role_profile_flags)
      when is_list(oauth_scopes) and is_map(role_profile_flags) do
    required = compute_required(role_profile_flags)
    missing = required -- oauth_scopes

    if missing == [], do: :ok, else: {:error, {:insufficient_scopes, missing}}
  end

  @doc """
  Liste des scopes requis pour un set de flags donnés.

  Utilitaire pur (pas d'IO), exposé pour les pré-flight check
  shell-side et la documentation runtime.
  """
  @spec compute_required(map()) :: [String.t()]
  def compute_required(role_profile_flags) when is_map(role_profile_flags) do
    base = @scopes_default

    base =
      if Map.get(role_profile_flags, "bridge_enabled", false),
        do: base ++ @scopes_bridge,
        else: base

    base = if Map.get(role_profile_flags, "mcp_oauth", false), do: base ++ @scopes_mcp, else: base
    base
  end
end
