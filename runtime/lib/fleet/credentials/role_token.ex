defmodule Fleet.Credentials.RoleToken do
  @moduledoc """
  Maps roles to forge accounts and requests their tokens from the authority service.
  Runtime token reads do not open local secret files. This module reports availability;
  RoleIdentity supplies the no-system-fallback construction policy.
  """

  require Logger

  @default_dir "/opt/lcars/var/tokens"

  @doc """
  Returns an authority-issued role token, or nil for failed login/token resolution.
  Errors are warning-logged; non-string input returns nil silently. No system fallback or
  token cache is supplied. Catalogue-map and Authority exceptions can propagate.
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
  Requests the token with a detailed authority cause instead of collapsing errors to nil.
  Login resolution errors/non-string input become no_forge_login. Boot policy needs to
  distinguish provisioning defects from retryable authority/forge outages; success still
  contains a secret, and each call makes a fresh request rather than retrieving a past cause.
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
  Names <dir>/<forge-login>.gitea_token after catalogue login resolution and path-safety checks.
  Returns :error for failed resolution or unsafe login; does not check file existence or contents.
  Account-prefixed filenames avoid collapsing different account identities onto a bare role path.
  Fixtures use this naming helper; runtime token requests leave file lookup to the authority.
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

  # Require exactly one tier separator and validate both path components. Slug itself allows '_';
  # the split, not Slug's charset, enforces the two-part login shape.
  defp path_safe?(login) do
    case String.split(login, "_") do
      [tier, role] -> Fleet.Slug.valid?(tier) and Fleet.Slug.valid?(role)
      _ -> false
    end
  end

  # Recheck issuance through Authority rather than relying on stale file-group membership.
  # This does not revoke copies of tokens previously returned.
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

  # Used only to name fixture paths; Authority owns runtime file reads and their diagnosis.
  @spec dir() :: String.t()
  defp dir, do: Application.get_env(:lcars_fleet, :credentials_role_tokens_dir) || @default_dir
end
