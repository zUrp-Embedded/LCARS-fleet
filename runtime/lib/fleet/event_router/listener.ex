defmodule Fleet.EventRouter.Listener do
  @moduledoc """
  Builds the Plug.Cowboy child specs shared by the runtime's HTTP surfaces.

  Bind policy is delegated to `Fleet.EventRouter.BindAddress`; callers retain
  their start-gate and port policies.
  """

  @doc """
  Builds a child spec from a required `:plug` and EITHER a `:port` or a `:socket`.

  Optional `:scheme` and `:ref` values are passed through; `:surface_env`
  selects the bind override. `:dispatch` must be a raw Cowboy dispatch because
  Plug.Cowboy compiles it internally.

  Both TCP and AF_UNIX use this builder, enforced by listener.no_cowboy_bypass, so
  bind policy has one implementation. TCP follows BindAddress overrides; AF_UNIX uses
  filesystem access instead. Port ranges, plug validity and socket path safety are not
  validated here; the caller and Cowboy own those preconditions.
  """
  @spec cowboy_child(keyword()) :: {module(), keyword()}
  def cowboy_child(opts) do
    plug = Keyword.fetch!(opts, :plug)

    # Reject conflicting transports rather than silently ignoring one caller-supplied address.
    base =
      case {Keyword.get(opts, :socket), Keyword.get(opts, :port)} do
        {nil, nil} ->
          raise ArgumentError, "cowboy_child/1 needs :port (TCP) or :socket (AF_UNIX)"

        {sock, nil} when is_binary(sock) ->
          # `port: 0` is what Cowboy requires alongside `{:local, path}` — it is not a port.
          [ip: {:local, sock}, port: 0]

        {nil, port} ->
          [ip: Fleet.EventRouter.BindAddress.ip(Keyword.get(opts, :surface_env)), port: port]

        {_sock, _port} ->
          raise ArgumentError, "cowboy_child/1: :socket and :port are exclusive"
      end

    options =
      base
      |> append_present(:dispatch, Keyword.get(opts, :dispatch))
      |> append_present(:ref, Keyword.get(opts, :ref))

    {Plug.Cowboy, scheme: Keyword.get(opts, :scheme, :http), plug: plug, options: options}
  end

  defp append_present(options, _key, nil), do: options
  defp append_present(options, key, value), do: options ++ [{key, value}]
end
