defmodule Fleet.Credentials.RoleToken do
  @moduledoc """
  Token forge du compte d'un RÔLE — pour que le système poste/commente EN SON NOM (issue par
  `Architect`, comment par `Engineer` → avatar honnête, traça vraie), via le token du compte de rôle.

  ## Source (path SYSTÈME, jamais un home utilisateur)

  Lu de `<role_tokens_dir>/<role>.gitea_token`. `role_tokens_dir` = config
  `:fleet_credentials, :role_tokens_dir`, **défaut `/home/private`** (répertoire de secrets, `700`).
  C'est un path **système absolu** — JAMAIS `System.user_home()` : la fleet est lancée PAR un humain
  (le BEAM hérite son UID, il n'existe pas de compte système `fleet`), mais les tokens de rôle sont un
  secret provisionné côté SYSTÈME, partagé par toutes les fleets per-humain — le path ne doit donc pas
  dépendre de QUI lance (l'override vit dans la config `role_tokens_dir`, pas dans le home).

  ## Agnosticité

  Le `role` est un **paramètre** — jamais un nom de rôle hardcodé dans le code. Il vient de l'identité
  du pod appelant (`metadata.name` du cap-profile = le rôle métier, propagé en env `LCARS_ROLE` puis
  injecté dans les tool calls par le pont MCP). `role` est validé **path-safe** (interpolé dans un path).
  """

  require Logger

  @default_dir "/home/private"

  @doc """
  Token forge du compte `role`, ou `nil` si absent/illisible/role invalide. Best-effort : le caller
  retombe sur le token système si `nil` (dégradé loggué — pas un masquage : le compte de rôle existe,
  c'est un trou de provisioning à voir, pas une erreur fatale).
  """
  @spec token(String.t() | nil) :: String.t() | nil
  def token(role) when is_binary(role) do
    # `role` est interpolé dans un path (`<dir>/<role>.gitea_token`) → validé via le smart-constructor
    # slug (source UNIQUE du charset path-safe ; un `role` malformé est ignoré, fallback token système).
    if Fleet.Slug.valid?(role) do
      path = Path.join(dir(), "#{role}.gitea_token")

      case File.read(path) do
        {:ok, content} ->
          case String.trim(content) do
            "" ->
              Logger.warning(
                "RoleToken: token de rôle #{inspect(role)} vide (#{path}) → fallback token " <>
                  "système (review/commit posté sous le compte système)"
              )

              nil

            token ->
              token
          end

        {:error, reason} ->
          Logger.warning(
            "RoleToken: token de rôle #{inspect(role)} absent/illisible (#{path} : " <>
              "#{inspect(reason)}) → fallback token système (review/commit posté sous le compte " <>
              "système)"
          )

          nil
      end
    else
      Logger.warning("RoleToken: role non path-safe #{inspect(role)} — ignoré")
      nil
    end
  end

  def token(_), do: nil

  @doc "Racine des tokens de rôle (`:fleet_credentials, :role_tokens_dir`, défaut `/home/private`)."
  @spec dir() :: String.t()
  def dir, do: Application.get_env(:fleet_credentials, :role_tokens_dir) || @default_dir
end
