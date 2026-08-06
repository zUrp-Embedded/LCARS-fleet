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
end
