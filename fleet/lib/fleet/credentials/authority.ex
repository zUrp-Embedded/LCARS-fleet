defmodule Fleet.Credentials.Authority do
  @moduledoc """
  The box's forge working credentials, ASKED at the moment they are used.

  ## Why this exists

  A forge account's token READ FROM A FILE — `<dir>/<account>.gitea_token`, mode `0640 root:fleet`,
  the group filled by the converger from the org's `humans` team — makes the right to hold a working
  identity a PROJECTION of a forge fact, with a projection's staleness: someone the forge has
  REMOVED keeps reading until the next tick, and until every live process of theirs dies. That is
  what makes revocation need `pkill`.

  Asked here, over a unix socket, the question carries no staleness. A removal bites on the next
  request, and the service on the other end knows WHO asked — the kernel says so (`SO_PEERCRED`),
  not the wire.

  ## What this is NOT

  ⚠ It hands out a credential. The service ACTS for `catalogue install` and nothing leaves; here it
  GIVES, and a given token still runs outside cards, gates and provenance. What is bought is real —
  no silent read, an attested identity, revocation that bites — and it is not "the audited path
  became mandatory". Claiming that would be selling.

  ## Fail-closed, and the causes stay apart

  Every failure returns `{:error, cause}` and never a token. The causes are not merged, because
  their remedies are opposite: a mute forge is retried, a missing authority is re-posed by an admin,
  and `:not_a_worker` means the forge removed you.
  """

  require Logger

  @default_socket "/run/lcars/authority/roles.sock"
  @timeout_ms 15_000

  @typedoc "Why no token was handed over. Never merged — see the moduledoc."
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
  The forge token of `account`, or a named cause.

  `account` is a forge ACCOUNT name (`system_starfleet`, `web-demo_dev`) — the same key the file
  layout used, because a token belongs to an account and not to a role name.
  """
  @spec token(String.t()) :: {:ok, String.t()} | {:error, cause()}
  def token(account) when is_binary(account) and account != "" do
    path = socket_path()

    # ⚠ `{:local, path}` AVEC `0` EN PORT : c'est la forme qu'Erlang exige pour AF_UNIX, et le zero
    # n'est pas un port — meme idiome que `pod_socket_acceptor` et le listener d'evenements.
    case :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false], @timeout_ms) do
      {:ok, sock} ->
        try do
          :ok = :gen_tcp.send(sock, account <> "\n")
          read_answer(sock, account)
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        # LA PORTE EST FERMEE, PAS GARDEE — et les deux ne se disent pas pareil. Une socket absente
        # est un geste SYSTEME (le service ne tourne pas) ; un refus est une reponse.
        Logger.error(
          "Authority: #{path} injoignable (#{inspect(reason)}) — le service d'autorite tourne-t-il ? " <>
            "Aucun credential de forge ne peut etre obtenu tant qu'il ne repond pas."
        )

        {:error, :authority_unreachable}
    end
  end

  def token(_), do: {:error, :bad_role}

  @doc """
  Where the authority service listens. Overridable — a witness cannot bind in `/run`.
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
        # ⚠ UNE ABSENCE DE REPONSE N'EST PAS UN REFUS, ET N'EST PAS UN OUI NON PLUS. On la nomme,
        # parce qu'un appelant qui la lirait comme « pas de jeton, tant pis » agirait sans identite.
        Logger.error("Authority: aucune reponse pour #{inspect(account)} (#{inspect(reason)})")
        {:error, :authority_mute}
    end
  end

  # Les causes du service sont un vocabulaire FERME. Une cause inconnue vient d'un service d'un
  # autre lot : on ne la range pas dans une cause voisine, on la nomme comme etrangere.
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
