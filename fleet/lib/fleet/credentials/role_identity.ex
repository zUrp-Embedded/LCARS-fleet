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
  The forge LOGIN `role` writes under, or `{:error, _}`.

  THE SECOND HALF OF THE IDENTITY, and it was missing. This module's whole subject is "who a role
  is on the forge", and it answered only the token: `as_role/2` handed callers the credential and
  nothing told them the ACCOUNT. So the runtime addressed accounts by the bare role name while the
  provisioning had created them as `<tier>_<role>`, and `request_review` asked a forge that has a
  `fleet_qualifier` for a `qualifier` — 404, a deliverable PR with no judge, and a merge waiting on
  approvals nobody had been asked for.

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
