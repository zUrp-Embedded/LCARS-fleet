defmodule Fleet.EventRouter.BindAddress do
  @moduledoc """
  SINGLE SOURCE of the bind IP for the runtime's HTTP listeners.

  Invariant established by construction (in one place, not by patching each
  call site separately):

  > Every runtime Cowboy listener binds the loopback `{127, 0, 0, 1}` by
  > default. A non-local exposure (all interfaces, or one specific interface)
  > is an EXPLICIT and NAMED opt-in — never the silent default.

  The runtime's security contract is "boundary = network / container
  isolation" (see `Fleet.API.Rest` § Auth, no-auth decks). That contract is
  only truly ENFORCED if the code forces the loopback bind: without `:ip`,
  Cowboy listens on `0.0.0.0` (all interfaces) and the boundary is no longer
  guaranteed by the runtime but delegated to an external firewall/network —
  implicit, hence fragile. This function is that single point of computation;
  a 5th listener that forgets it is the only way to regress (and it is caught
  by each surface's bind tests).

  ## Exposure override (named opt-in)

  Two levels, from most specific to most global:

    1. **Per-surface** — the caller names a dedicated env var (e.g.
       `LCARS_WEBHOOK_BIND_HOST` for the forge webhook, the only surface whose
       public exposure is a legitimate need: a remote forge POSTs to the
       webhook, loopback would block it). Presence of the env = a clear
       intention to expose THIS surface.
    2. **Global** — `LCARS_BIND_HOST` exposes ALL listeners (a deployment
       behind a trusted network that takes on the isolation itself).

  The per-surface override wins over the global one. Neither present → loopback.

  An env value is a host: either a literal IP (`0.0.0.0`, `192.168.1.10`,
  `::`, …) or a name resolved via DNS. We stay on TCP (no Unix socket) — this
  is only the listening socket's `ip`.
  """

  @loopback {127, 0, 0, 1}

  @doc """
  Bind IP to pass in the transport options of a Cowboy listener
  (`options: [ip: ...]` for Plug.Cowboy; `:host` for the ExMCP HTTP transport,
  which derives it itself).

  `surface_env` (optional) = name of the override env var SPECIFIC to this
  surface. If it is set, its value wins. Otherwise we fall back to the global
  override `LCARS_BIND_HOST`. Otherwise loopback `{127, 0, 0, 1}`.

  Returns an `:inet.ip_address()` address tuple (IPv4 or IPv6).
  """
  @spec ip(String.t() | nil) :: :inet.ip_address()
  def ip(surface_env \\ nil) do
    case override_host(surface_env) do
      nil -> @loopback
      host -> parse_host(host)
    end
  end

  # Per-surface override (if named and set) THEN global override. An empty env
  # ("") does not count as an override — an accidentally emptied export must not
  # re-expose a listener.
  defp override_host(surface_env) do
    surface_value =
      case surface_env do
        nil -> nil
        name -> presence(System.get_env(name))
      end

    surface_value || presence(System.get_env("LCARS_BIND_HOST"))
  end

  defp presence(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  # Host → IP tuple. Literal IP parsed directly (IPv4/IPv6); otherwise DNS
  # resolution. An invalid override value (neither an IP nor a resolvable name)
  # MUST fail loud: an operator explicitly asked for a public exposure, silently
  # falling back to loopback would mask their intention (they would believe it
  # exposed when it is not). We refuse the boot instead, with a clear message.
  defp parse_host(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        ip

      {:error, :einval} ->
        case :inet.getaddr(charlist, :inet) do
          {:ok, ip} ->
            ip

          {:error, reason} ->
            raise ArgumentError,
                  "LCARS bind host #{inspect(host)} invalid — neither an IP nor a resolvable " <>
                    "name (#{inspect(reason)}). Fix the exposure env (LCARS_BIND_HOST or the " <>
                    "surface override); boot refused."
        end
    end
  end
end
