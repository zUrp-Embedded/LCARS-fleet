defmodule Fleet.Credentials.RoleIdentity do
  @moduledoc """
  Fail-closed smart constructor for forge role identity. A struct requires a
  verified non-empty token, making silent fallback to the privileged system account
  unrepresentable. `RoleToken` only reports availability; policy lives here.
  """
  alias Fleet.Credentials.RoleToken

  @enforce_keys [:role, :token]
  defstruct [:role, :token]

  @type t :: %__MODULE__{role: String.t(), token: String.t()}

  @doc """
  Builds the verified identity for `role`, or `{:error, :role_token_unavailable}` if its token cannot be
  resolved (absent / unreadable / empty file, or a non-path-safe role). Never yields a struct with a nil
  token (`@enforce_keys`), so downstream code cannot construct a "role identity" that is really the system
  account.
  """
  @spec for_role(String.t()) :: {:ok, t()} | {:error, :role_token_unavailable}
  def for_role(role) when is_binary(role) and role != "" do
    case RoleToken.token(role) do
      token when is_binary(token) and token != "" -> {:ok, %__MODULE__{role: role, token: token}}
      _ -> {:error, :role_token_unavailable}
    end
  end

  def for_role(_), do: {:error, :role_token_unavailable}

  @doc """
  POURQUOI `for_role/1` a refusé — la cause, sans le jeton.

  ## Ce que ce module refuse de faire, et pourquoi il l'expose quand même

  `for_role/1` rend UNE forme d'échec, `:role_token_unavailable`, et c'est sa politique : les
  appelants du domaine agissent pareil dans tous les cas, ils ferment. Leur donner les causes les
  ferait décider au cas par cas, chacun à sa façon.

  Un appelant a pourtant besoin de les séparer, et il est hors du domaine : le garde de BOOT du
  rail. Depuis que le jeton se demande à un service, « pas de jeton » recouvre un défaut de
  provisionnement (LOCAL, définitif — le conteneur ne doit pas démarrer) et une porte qui ne répond pas
  (TRANSITOIRE — refuser le boot dessus échangerait une panne rattrapable contre un conteneur mort).

  ⚠ CE N'EST PAS UNE PORTE DE REPLI. Elle ne rend jamais de jeton que `for_role/1` aurait refusé —
  elle rend `{:ok, _}` seulement là où `for_role/1` aurait réussi. Ce qui se lit ici est un
  DIAGNOSTIC, jamais une seconde chance.
  """
  @spec token_cause(String.t() | nil) ::
          {:ok, String.t()} | {:error, Fleet.Credentials.Authority.cause() | :no_forge_login}
  defdelegate token_cause(role), to: RoleToken, as: :token_result

  @doc """
  Where `role`'s forge token lives — `<dir>/<login>.gitea_token`, or `:error`.

  The third face of the same identity, beside the token and the account: a credential FILE is named
  after the account that owns it. Exposed here because this module is the domain's door on "who a
  role is on the forge", and `RoleToken` is internal to it.
  """
  @spec token_path(String.t()) :: {:ok, Path.t()} | :error
  defdelegate token_path(role), to: RoleToken, as: :path_for

  @doc """
  The forge LOGIN `role` writes under, or `{:error, _}`.

  THE SECOND HALF OF THE IDENTITY. This module's subject is "who a role is on the forge", and
  answering only the token leaves callers holding a credential with nothing to tell them the
  ACCOUNT: the runtime then addresses accounts by the BARE ROLE NAME while the provisioning created
  them as `<tier>_<role>`, so `request_review` asks a forge that has a `<tier>_qualifier` for a
  `qualifier` — 404, a deliverable PR with no judge, and a merge waiting on approvals NOBODY WAS
  ASKED FOR.

  The RULE lives in `Fleet.CapProfile.forge_login/1` (the roster and the tier split are its
  subject); this is the door the forge side comes through, so the two halves of an identity are
  reached from one module.
  """
  @spec login(String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate login(role), to: Fleet.CapProfile, as: :forge_login

  @doc """
  The role behind a forge `login`, or `{:error, {:login_not_a_role, login}}`.
  """
  @spec role_of_login(String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate role_of_login(login), to: Fleet.CapProfile, as: :role_of_forge_login

  @doc """
  The FLEET-side name of a forge account: its role, or the login unchanged when it belongs to none.

  The read frontier. A forge answers in logins; the fleet reasons in roles; and a name that is
  neither is a HUMAN, which must stay visibly foreign rather than be coerced into the jury (F-C061
  — a stranger who reads as a role can skew or block a verdict). So: translate what is ours, leave
  the rest exactly as it came.
  """
  @spec role_or_login(String.t()) :: String.t()
  def role_or_login(login) when is_binary(login) do
    case role_of_login(login) do
      {:ok, role} -> role
      {:error, _} -> login
    end
  end
end
