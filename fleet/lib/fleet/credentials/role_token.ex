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
    case path_for(role) do
      {:ok, path} -> read_at(role, path)
      :error -> nil
    end
  end

  def token(_), do: nil

  @doc """
  Where `role`'s token lives — `<dir>/<forge login>.gitea_token`, or `:error`.

  KEYED BY THE ACCOUNT, and that is the same distinction the forge frontier draws everywhere else:
  a token belongs to an ACCOUNT (`<tier>_<role>`), while a role name is only unique inside its own
  catalogue. It used to be keyed by the bare role, so two catalogues each declaring a `writer` wrote
  and read ONE `writer.gitea_token`: whichever was provisioned second took over the other's
  identity, and nothing could report it — the file exists and its content is a valid token. The
  ACCOUNT was already prefixed for exactly that reason; the file was not.

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

  defp read_at(role, path) do
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
  end

  @doc "Root of the role tokens (`:fleet_credentials, :role_tokens_dir`, default `/home/private`)."
  @spec dir() :: String.t()
  def dir, do: Application.get_env(:fleet_credentials, :role_tokens_dir) || @default_dir
end
