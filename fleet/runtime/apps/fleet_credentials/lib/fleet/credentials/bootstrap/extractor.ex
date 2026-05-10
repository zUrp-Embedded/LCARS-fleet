defmodule Fleet.Credentials.Bootstrap.Extractor do
  @moduledoc """
  Extraction post-`claude /login` user-side → coffre LCARS.

  Lit `~/.claude/.credentials.json` après que l'utilisateur a
  exécuté `claude /login` interactif (PTY user-side, F-MIX-PTY-PATTERN).
  Valide le schema OAuth canonique (PoC-23, 6 champs requis), vérifie
  que les scopes couvrent le minimum requis pour le rôle, puis écrit
  atomiquement le coffre `/var/lib/lcars/credentials/<role>/`.

  Refuse l'install si scopes insuffisants → l'utilisateur doit
  re-`claude /login` avec un compte plan Pro/Max et scopes complets.

  ## Schema OAuth canon (PoC-23)

  Le fichier `~/.claude/.credentials.json` doit contenir une clé
  `claudeAiOauth` (objet) avec les 6 champs :

    * `accessToken` — string
    * `refreshToken` — string
    * `expiresAt` — integer ms epoch
    * `scopes` — list of strings
    * `subscriptionType` — string (`"pro"` | `"max"`)
    * `rateLimitTier` — string (informatif)

  ## Exit codes

    * `{:ok, role}` — coffre écrit, success
    * `{:error, {:credentials_file_unreadable, path, reason}}`
    * `{:error, {:credentials_json_invalid, reason}}`
    * `{:error, {:schema_invalid, missing_keys}}`
    * `{:error, {:insufficient_scopes, missing}}`
  """

  @required_keys ~w(accessToken refreshToken expiresAt scopes subscriptionType rateLimitTier)

  @doc """
  Extrait les credentials du fichier source et écrit le coffre.

  ## Options

    * `:home` — répertoire home utilisateur (default `System.user_home!/0`)
    * `:role` — rôle cible (obligatoire)
    * `:role_profile_flags` — map flags pour scope-coverage check
      (default `%{}` = scopes minimum requis)
  """
  @spec extract(keyword()) ::
          {:ok, String.t()}
          | {:error, term()}
  def extract(opts) when is_list(opts) do
    role = Keyword.fetch!(opts, :role)
    home = Keyword.get(opts, :home, System.user_home!())
    flags = Keyword.get(opts, :role_profile_flags, %{})
    creds_file = Path.join([home, ".claude", ".credentials.json"])

    with {:ok, raw} <- read_credentials_file(creds_file),
         {:ok, parsed} <- decode_json(raw),
         {:ok, oauth} <- extract_oauth(parsed),
         :ok <- validate_schema(oauth),
         :ok <- Fleet.Credentials.ScopeValidator.validate(oauth["scopes"], flags) do
      :ok = Fleet.Credentials.Store.write_atomic_coffre(role, oauth)
      {:ok, role}
    end
  end

  defp read_credentials_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:credentials_file_unreadable, path, reason}}
    end
  end

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:credentials_json_invalid, reason}}
    end
  end

  defp extract_oauth(%{"claudeAiOauth" => oauth}) when is_map(oauth), do: {:ok, oauth}
  defp extract_oauth(_), do: {:error, {:schema_invalid, ["claudeAiOauth"]}}

  defp validate_schema(oauth) do
    missing = Enum.reject(@required_keys, &Map.has_key?(oauth, &1))
    if missing == [], do: :ok, else: {:error, {:schema_invalid, missing}}
  end
end
