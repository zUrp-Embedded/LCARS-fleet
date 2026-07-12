defmodule Fleet.Credentials.RoleIdentity do
  @moduledoc """
  Smart-constructor for a role's forge identity. A `%RoleIdentity{}` CANNOT be built without a VERIFIED,
  non-empty role token: `for_role/1` returns `{:error, :role_token_unavailable}` when the role's token is
  absent / unreadable / empty (or the role is not path-safe). It makes "act as role X on the forge" a value
  that is UNREPRESENTABLE when the token is missing — so a consumer (pilot `ForgeClient.as_role`, mcp
  `Delegation.create_issue`) can NEVER silently fall back to the SYSTEM token, which would be a privilege
  ESCALATION (the system account is the most powerful) and would break forge traceability (wrong actor).
  The void (nil token) is caught HERE, at construction, not at the forge-write site.

  `RoleToken` stays policy-NEUTRAL (it reports `nil` + a warning); THIS module carries the fail-closed
  policy, shared by both consumers — a single source, no divergence (the former split was pilot fail-OPEN
  vs mcp fail-CLOSED on the very same `nil`).
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
