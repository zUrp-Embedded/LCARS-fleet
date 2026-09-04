defmodule Fleet.Credentials.RoleToken do
  @moduledoc """
  Reads path-safe role-account forge tokens from the system secret directory,
  never a user home or wire-supplied identity. The role is resolved server-side;
  this module returns token availability without deciding fallback policy.
  """

  require Logger

  @default_dir "/opt/lcars/var/tokens"

  @doc """
  Forge token of the `role` account, or `nil` if absent/unreadable/invalid role.

  `nil` REPORTS the absence (every cause is warning-logged here), it is NOT a policy: this module stays policy-NEUTRAL.
  The fail-CLOSED policy is carried by the `Fleet.Credentials.RoleIdentity` smart-constructor, the SINGLE
  source shared by both consumers (pilot `ForgeClient.as_role/2`, mcp `Delegation.create_issue`): a `nil`
  token yields `{:error, :role_token_unavailable}` and NEVER a system-account fallback (which would be a
  privilege escalation + a traceability lie). This module neither fails open nor closed — it reports.
  """
  @spec token(String.t() | nil) :: String.t() | nil
  def token(role) when is_binary(role) do
    case Fleet.CapProfile.forge_login(role) do
      {:ok, login} -> ask_authority(role, login)
      {:error, reason} -> no_login(role, reason)
    end
  end

  def token(_), do: nil

  @doc """
  La MEME resolution que `token/1`, mais qui rend la CAUSE au lieu de `nil`.

  ## Pourquoi les deux existent

  `token/1` garde son contrat — un jeton, ou `nil` — et c'est ce qui a permis de deplacer la lecture
  vers le service d'autorite sans toucher une ligne chez ses appelants. Ce contrat est aussi une
  PERTE D'INFORMATION deliberee : la politique fail-closed vit chez `RoleIdentity`, qui n'a pas a
  connaitre les causes.

  Un appelant a pourtant besoin de les separer : le garde de BOOT du rail. « Pas de jeton » ne
  designe PAS une seule chose — c'est a la fois « le provisionnement n'a pas tourne » (LOCAL,
  definitif : la boite est mal deployee et ne doit pas demarrer), « le service d'autorite ne tourne
  pas encore » et « la forge n'a pas repondu », ces deux-la etant TRANSITOIRES et distants. Refuser
  le boot dessus echangerait une panne rattrapable contre une boite morte, ET LE MESSAGE ACCUSERAIT
  LE PROVISIONNEMENT.
  """
  @spec token_result(String.t() | nil) ::
          {:ok, String.t()} | {:error, Fleet.Credentials.Authority.cause() | :no_forge_login}
  def token_result(role) when is_binary(role) do
    case Fleet.CapProfile.forge_login(role) do
      {:ok, login} -> Fleet.Credentials.Authority.token(login)
      {:error, _reason} -> {:error, :no_forge_login}
    end
  end

  def token_result(_), do: {:error, :no_forge_login}

  @doc """
  Where `role`'s token lives — `<dir>/<forge login>.gitea_token`, or `:error`.

  KEYED BY THE ACCOUNT, and that is the same distinction the forge frontier draws everywhere else:
  a token belongs to an ACCOUNT (`<tier>_<role>`), while a role name is only unique inside its own
  catalogue. Keyed by the BARE ROLE, two catalogues each declaring a `writer` write and read ONE
  `writer.gitea_token`: whichever is provisioned second TAKES OVER the other's identity, and nothing
  can report it — the file exists and its content is a valid token. The ACCOUNT is prefixed for
  exactly that reason; the file must be too.

  A role no catalogue declares has NO account, therefore no token path — `:error`. That closes the
  door the flat namespace left open: a caller could name any string and be handed a credential for
  it, which is how two test fixtures came to hold tokens for roles that exist nowhere.

  THE SINGLE AUTHORITY of that path, fixtures included. A fixture that spells the file itself is a
  fixture that keeps passing on a scheme the runtime no longer uses.
  """
  @spec path_for(String.t()) :: {:ok, Path.t()} | :error
  def path_for(role) when is_binary(role) do
    with {:ok, login} <- Fleet.CapProfile.forge_login(role),
         true <- path_safe?(login) do
      {:ok, Path.join(dir(), "#{login}.gitea_token")}
    else
      {:error, reason} ->
        Logger.warning(
          "RoleToken: no forge login for role #{inspect(role)} (#{inspect(reason)}) — no token " <>
            "path (caller policy in RoleIdentity: fail-closed, no system-account fallback)"
        )

        :error

      false ->
        Logger.warning("RoleToken: non path-safe login for role #{inspect(role)} — ignored")
        :error
    end
  end

  def path_for(_), do: :error

  # The login is interpolated into a path. `Fleet.Slug` stays the SINGLE source of the path-safe
  # charset and it rejects `_`, which a login carries exactly once by construction — so each half is
  # validated on its own. Confinement unchanged: no separator, no traversal, no dot segment.
  defp path_safe?(login) do
    case String.split(login, "_") do
      [tier, role] -> Fleet.Slug.valid?(tier) and Fleet.Slug.valid?(role)
      _ -> false
    end
  end

  # ⚠ LE JETON SE DEMANDE, IL NE SE LIT PAS. Un fichier en `0640 root:fleet` est lisible par TOUT
  # humain de la boite, et ce groupe est une PROJECTION de l'equipe `humans` de la forge, refaite
  # periodiquement : le droit de porter une identite de travail aurait alors LA PEREMPTION D'UN
  # CACHE, et quelqu'un que la forge a retire lirait encore jusqu'au tour suivant.
  #
  # La question est posee au service d'autorite, qui la pose a la forge. Elle ne porte pas de
  # peremption, et le service sait QUI demande — le noyau le lui dit.
  #
  # ⚠ LE CONTRAT NE BOUGE PAS : un jeton, ou `nil`. Tout le fail-closed des appelants
  # (`RoleIdentity.for_role/1` -> `{:error, :role_token_unavailable}`) continue de valoir sans une
  # ligne de changement chez eux — c'est ce qui rend ce deplacement jouable en un seul geste.
  defp ask_authority(role, login) do
    case Fleet.Credentials.Authority.token(login) do
      {:ok, token} ->
        token

      {:error, cause} ->
        Logger.warning(
          "RoleToken: no token for role #{inspect(role)} (compte #{inspect(login)}) — " <>
            "#{inspect(cause)} → unavailable (caller policy in RoleIdentity: fail-closed, no " <>
            "system-account fallback)"
        )

        nil
    end
  end

  defp no_login(role, reason) do
    Logger.warning(
      "RoleToken: no forge login for role #{inspect(role)} (#{inspect(reason)}) — no account to " <>
        "ask for (caller policy in RoleIdentity: fail-closed, no system-account fallback)"
    )

    nil
  end

  # ⚠ LE BEAM NE LIT AUCUN FICHIER DE JETON, ET NE SONDE PAS LEUR REPERTOIRE. Il demande au service
  # d'autorite, qui possede le repertoire et resout le chemin de son cote ; un repertoire absent est
  # SON diagnostic (`no_role_token`), pas le notre. `dir/0` est prive et n'a qu'un appelant,
  # `path_for/1`, qui NOMME le fichier sans l'ouvrir — pour les fixtures de la suite, qui posent un
  # jeton la ou le double d'autorite le lira. Le knob `:credentials_role_tokens_dir` steere
  # `runtime.exs` et ce double ; aucun lecteur de runtime ne s'en sert.
  @spec dir() :: String.t()
  defp dir, do: Application.get_env(:lcars_fleet, :credentials_role_tokens_dir) || @default_dir
end
