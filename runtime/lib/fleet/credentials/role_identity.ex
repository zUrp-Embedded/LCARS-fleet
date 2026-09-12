defmodule Fleet.Credentials.RoleIdentity do
  @moduledoc """
  Constructs forge-role identities without fallback to the privileged system account.
  for_role/1 requires a non-empty token from RoleToken; it does not validate it with the forge.
  Direct struct construction bypasses that check: enforce_keys requires keys, not valid values.
  """
  alias Fleet.Credentials.RoleToken

  @enforce_keys [:role, :token]
  defstruct [:role, :token]

  @type t :: %__MODULE__{role: String.t(), token: String.t()}

  @doc """
  Resolves the role's forge account through RoleToken and accepts a non-empty token.
  Unavailable tokens or invalid role input return role_token_unavailable without a system fallback.
  Authority transport exceptions and catalogue-map construction failures can still propagate.
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
  Performs a fresh token request, returning {:ok, token} or the detailed cause.
  Unlike for_role/1's collapsed refusal, boot callers can distinguish provisioning defects from
  transient authority/forge failures. Success contains secret material: this is not a token-free
  diagnostic or the saved cause of a previous request, and no fallback identity is supplied.
  """
  @spec token_cause(String.t() | nil) ::
          {:ok, String.t()} | {:error, Fleet.Credentials.Authority.cause() | :no_forge_login}
  defdelegate token_cause(role), to: RoleToken, as: :token_result

  @doc """
  Names <dir>/<forge-login>.gitea_token, or returns :error when login/path resolution fails.
  Does not read or check the file; runtime token requests go through the authority service.
  """
  @spec token_path(String.t()) :: {:ok, Path.t()} | :error
  defdelegate token_path(role), to: RoleToken, as: :path_for

  @doc """
  Resolves a role's forge login through CapProfile.forge_login/1, preserving its errors/raises.
  Forge requests need the tier-prefixed account, not the bare role, to reach provisioned reviewers.
  """
  @spec login(String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate login(role), to: Fleet.CapProfile, as: :forge_login

  @doc """
  The role behind a forge `login`, or `{:error, {:login_not_a_role, login}}`.
  """
  @spec role_of_login(String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate role_of_login(login), to: Fleet.CapProfile, as: :role_of_forge_login

  @doc """
  Returns the resolved role, or the original login on any resolution error (including map-read
  failures). Unknown humans/bots must remain foreign to jury membership; this display conversion
  is not an authorization check.
  """
  @spec role_or_login(String.t()) :: String.t()
  def role_or_login(login) when is_binary(login) do
    case role_of_login(login) do
      {:ok, role} -> role
      {:error, _} -> login
    end
  end
end
