defmodule Fleet.Credentials.RoleToken do
  @moduledoc """
  Forge token of a ROLE's account — so the system posts/comments IN ITS NAME (issue by
  `Architect`, comment by `Engineer` → honest avatar, true traceability), via the role account's token.

  ## Source (SYSTEM path, never a user home)

  Read from `<role_tokens_dir>/<role>.gitea_token`. `role_tokens_dir` = config
  `:fleet_credentials, :role_tokens_dir`, **default `/home/private`** (secrets directory, `700`).
  The placement is mechanized: `etc/provision-role-tokens.sh` (idempotent mint per forge,
  privileged run once; `--check` = validity probe, reused by the nuke-drill).
  One set per forge (cf. env `FORGE_ROLE_TOKENS_DIR`, read by runtime.exs).
  This is an **absolute system path** — NEVER `System.user_home()`: the fleet is launched BY a human
  (the BEAM inherits their UID, there is no `fleet` system account), but role tokens are a
  secret provisioned on the SYSTEM side, shared by all per-human fleets — so the path must NOT
  depend on WHO launches (the override lives in the `role_tokens_dir` config, not in the home).

  ## Agnosticity

  The `role` is a **parameter** — never a role name hardcoded in the code. It comes from the identity
  of the calling pod (`metadata.name` of the cap-profile = the business role, propagated in env `LCARS_ROLE` then
  injected into the tool calls by the MCP bridge). `role` is validated **path-safe** (interpolated into a path).
  """

  require Logger

  @default_dir "/home/private"

  @doc """
  Forge token of the `role` account, or `nil` if absent/unreadable/invalid role.

  `nil` is a best-effort REPORTING of absence (logged here), NOT a policy: this module stays policy-NEUTRAL.
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
