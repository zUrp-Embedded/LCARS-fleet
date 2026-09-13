defmodule Fleet.Credentials.Authority do
  @moduledoc """
  Requests forge-account tokens from the authority Unix socket on each call, without caching.
  The service authenticates peers through SO_PEERCRED and checks forge membership instead of
  relying on periodically projected file-read groups. This client does not itself check membership
  or revoke tokens already handed out; returned credentials can be used outside the audited workflow.

  Named causes distinguish membership/provisioning refusals from transport failure so callers
  can choose the right remedy. Connect failures return authority_unreachable; receive failures,
  empty replies and unknown FAIL causes return authority_mute. A failed send can raise.
  """

  require Logger

  @default_socket "/run/lcars/authority/roles.sock"
  @timeout_ms 15_000

  @typedoc "Known authority refusals and transport categories; unknown FAIL causes map to authority_mute."
  @type cause ::
          :not_a_worker
          | :bad_role
          | :no_role_token
          | :no_authority
          | :forge_unreachable
          | :unknown_peer
          | :authority_unreachable
          | :authority_mute

  @doc """
  Requests a forge account's token (for example system_starfleet), not a bare role's token.
  Rejects empty/non-string input; other account syntax is not checked before line framing.
  Connect and receive each have a 15-second timeout. Any non-empty non-FAIL reply is accepted
  as token text, without token validation; sockets close after send/read, including exceptions.
  """
  @spec token(String.t()) :: {:ok, String.t()} | {:error, cause()}
  def token(account) when is_binary(account) and account != "" do
    path = socket_path()

    # Erlang's AF_UNIX form requires port zero alongside the local path.
    case :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false], @timeout_ms) do
      {:ok, sock} ->
        try do
          :ok = :gen_tcp.send(sock, account <> "\n")
          read_answer(sock, account)
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        Logger.error(
          "Authority: #{path} injoignable (#{inspect(reason)}) — le service d'autorite tourne-t-il ? " <>
            "Aucun credential de forge ne peut etre obtenu tant qu'il ne repond pas."
        )

        {:error, :authority_unreachable}
    end
  end

  def token(_), do: {:error, :bad_role}

  @doc """
  Returns the socket path: credentials_authority_socket app config, then LCARS_ROLES_SOCKET,
  then the built-in /run path. Overrides let tests bind outside /run.
  """
  @spec socket_path() :: Path.t()
  def socket_path do
    Application.get_env(:lcars_fleet, :credentials_authority_socket) ||
      System.get_env("LCARS_ROLES_SOCKET") || @default_socket
  end

  defp read_answer(sock, account) do
    case :gen_tcp.recv(sock, 0, @timeout_ms) do
      {:ok, line} ->
        case String.trim_trailing(line, "\n") do
          "FAIL:" <> cause ->
            atom = cause_atom(cause)

            Logger.warning("Authority: pas de jeton pour #{inspect(account)} — #{inspect(atom)}")

            {:error, atom}

          "" ->
            {:error, :authority_mute}

          token ->
            {:ok, token}
        end

      {:error, reason} ->
        Logger.error("Authority: aucune reponse pour #{inspect(account)} (#{inspect(reason)})")
        {:error, :authority_mute}
    end
  end

  # Closed vocabulary avoids creating atoms from the wire; suffix detail is discarded.
  defp cause_atom(raw) do
    case raw |> String.split(":") |> hd() do
      "not_a_worker" -> :not_a_worker
      "bad_role" -> :bad_role
      "no_role_token" -> :no_role_token
      "no_authority" -> :no_authority
      "forge_unreachable" -> :forge_unreachable
      "unknown_peer" -> :unknown_peer
      _ -> :authority_mute
    end
  end
end
