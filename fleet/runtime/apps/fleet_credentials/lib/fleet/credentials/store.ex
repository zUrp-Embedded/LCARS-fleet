defmodule Fleet.Credentials.Store do
  @moduledoc """
  Logique I/O coffre partagée par `Fleet.Credentials.OAuthRefresher`
  (refresh) et `Fleet.Credentials.Bootstrap.Extractor` (install
  initial).

  Module pure data transformer (pas de processus). Centralise l'écriture
  atomique des 4 fichiers du coffre (`oauth_refresh_token`,
  `oauth_access_token`, `oauth_scopes`, `expires_at`) via le pattern
  POSIX `tmp + File.rename!/2`.

  ## Atomic write

  Chaque fichier est écrit via `<role_dir>/.<file>.tmp` puis
  `File.rename!/2` (POSIX atomic sur même filesystem). Aucun fichier
  intermédiaire `.tmp` ne subsiste après succès. Les 4 fichiers sont
  écrits séquentiellement dans cet ordre : refresh, access, scopes,
  expires_at — `expires_at` en dernier pour que le prochain `init/1`
  GenServer voie un coffre cohérent (mode dégradé : si `expires_at`
  écrit échoue, le prochain refresh démarre avec l'ancien `expires_at`
  → refresh anticipé, pas de corruption).

  ## Encodage scopes

  Le SDK retourne `scopes` soit en liste (cas standard), soit en string
  pré-jointe (cas dégradé). `encode_scopes/1` accepte les deux et
  produit un string space-séparé canonique pour le coffre.
  """

  @doc """
  Écrit atomiquement le coffre `<creds_root>/<role>/` à partir d'un
  map de credentials OAuth (schema PoC-23).

  ## Inputs

    * `role` — string, sous-répertoire dans `Fleet.Credentials.creds_root/0`
    * `creds` — map avec clés `"refreshToken"`, `"accessToken"`,
      `"scopes"` (list ou string), `"expiresAt"` (integer ms epoch)

  ## Returns

  `:ok` (raise sur erreur I/O — pas de fallback silencieux, le caller
  doit décider du recovery).
  """
  @spec write_atomic_coffre(String.t(), map()) :: :ok
  def write_atomic_coffre(role, creds) when is_binary(role) and is_map(creds) do
    role_dir = Path.join(Fleet.Credentials.creds_root(), role)
    File.mkdir_p!(role_dir)

    files = [
      {"oauth_refresh_token", creds["refreshToken"]},
      {"oauth_access_token", creds["accessToken"]},
      {"oauth_scopes", encode_scopes(creds["scopes"])},
      {"expires_at", to_string(creds["expiresAt"])}
    ]

    Enum.each(files, fn {file, content} ->
      tmp_path = Path.join(role_dir, "." <> file <> ".tmp")
      final_path = Path.join(role_dir, file)
      File.write!(tmp_path, to_string(content))
      File.rename!(tmp_path, final_path)
    end)

    :ok
  end

  @doc """
  Encode une valeur `scopes` (list ou string) en string space-séparé.

  ## Examples

      iex> Fleet.Credentials.Store.encode_scopes(["a", "b"])
      "a b"

      iex> Fleet.Credentials.Store.encode_scopes("a b")
      "a b"

      iex> Fleet.Credentials.Store.encode_scopes(nil)
      ""
  """
  @spec encode_scopes(list() | String.t() | nil) :: String.t()
  def encode_scopes(scopes) when is_list(scopes), do: Enum.join(scopes, " ")
  def encode_scopes(scopes) when is_binary(scopes), do: scopes
  def encode_scopes(nil), do: ""
end
