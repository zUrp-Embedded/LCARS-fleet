defmodule Fleet.EventRouter.BindAddress do
  @moduledoc """
  Resolves the bind IP shared by the runtime's HTTP listeners.

  Listeners bind to loopback by default. A named per-surface environment
  override wins over `LCARS_BIND_HOST`; blank values are ignored. Overrides
  accept literal IPs or DNS names and invalid values raise.
  """

  @loopback {127, 0, 0, 1}

  @doc """
  Returns the IPv4 or IPv6 bind address for an optional surface override.
  """
  @spec ip(String.t() | nil) :: :inet.ip_address()
  def ip(surface_env \\ nil) do
    case override_host(surface_env) do
      nil -> @loopback
      host -> parse_host(host)
    end
  end

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
