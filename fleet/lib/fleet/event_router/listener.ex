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

  ## Why the AF_UNIX case lives HERE and not in its caller

  6-072/6-098. This file is the SINGLE builder of a Cowboy child spec, held by
  `mix lcars.contracts.check`, rail `listener.no_cowboy_bypass`, whose remediation says to route
  through here — a unix listener writing its own `{Plug.Cowboy, ...}` tuple is refused there.

  The reason survives the change of transport: with two builders, the second drifts. The TCP branch
  is loopback-by-construction; nothing would force a second builder to stay that way, and the whole
  point of the unix branch is that it has no address to get wrong. Keeping both in one function is
  what makes "how this runtime binds an HTTP surface" a single readable answer.
  """
  @spec cowboy_child(keyword()) :: {module(), keyword()}
  def cowboy_child(opts) do
    plug = Keyword.fetch!(opts, :plug)

    # `:socket` and `:port` are EXCLUSIVE, and the refusal is loud: a spec carrying both would bind
    # one of them and silently ignore the other — the caller would be certain of the wrong one.
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
