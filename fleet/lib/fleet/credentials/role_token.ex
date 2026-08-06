defmodule Fleet.Credentials.RoleToken do
  @moduledoc """
  Reads path-safe role-account forge tokens from the system secret directory,
  never a user home or wire-supplied identity. The role is resolved server-side;
  this module returns token availability without deciding fallback policy.
  """

  require Logger

  @default_dir "/home/private"

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
    # `role` is interpolated into a path (`<dir>/<role>.gitea_token`) → validated via the slug
    # smart-constructor (SINGLE source of the path-safe charset; a malformed `role` returns nil — caller fail-closes via RoleIdentity).
    if Fleet.Slug.valid?(role) do
      path = Path.join(dir(), "#{role}.gitea_token")

      case File.read(path) do
        {:ok, content} ->
          case String.trim(content) do
            "" ->
              Logger.warning(
                "RoleToken: role token #{inspect(role)} empty (#{path}) → unavailable " <>
                  "(caller policy in RoleIdentity: fail-closed, no system-account fallback)"
              )

              nil

            token ->
              token
          end

        {:error, reason} ->
          Logger.warning(
            "RoleToken: role token #{inspect(role)} absent/unreadable (#{path} : " <>
              "#{inspect(reason)}) → unavailable (caller policy in RoleIdentity: fail-closed, " <>
              "no system-account fallback)"
          )

          nil
      end
    else
      Logger.warning("RoleToken: non path-safe role #{inspect(role)} — ignored")
      nil
    end
  end

  def token(_), do: nil

  @doc "Root of the role tokens (`:fleet_credentials, :role_tokens_dir`, default `/home/private`)."
  @spec dir() :: String.t()
  def dir, do: Application.get_env(:fleet_credentials, :role_tokens_dir) || @default_dir
end
