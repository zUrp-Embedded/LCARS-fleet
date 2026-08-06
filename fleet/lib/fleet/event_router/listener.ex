defmodule Fleet.EventRouter.Listener do
  @moduledoc """
  Builds the Plug.Cowboy child specs shared by the runtime's HTTP surfaces.

  Bind policy is delegated to `Fleet.EventRouter.BindAddress`; callers retain
  their start-gate and port policies.
  """

  @doc """
  Builds a child spec from required `:plug` and `:port` options.

  Optional `:scheme` and `:ref` values are passed through; `:surface_env`
  selects the bind override. `:dispatch` must be a raw Cowboy dispatch because
  Plug.Cowboy compiles it internally.
  """
  @spec cowboy_child(keyword()) :: {module(), keyword()}
  def cowboy_child(opts) do
    plug = Keyword.fetch!(opts, :plug)
    port = Keyword.fetch!(opts, :port)
    ip = Fleet.EventRouter.BindAddress.ip(Keyword.get(opts, :surface_env))

    options =
      [ip: ip, port: port]
      |> append_present(:dispatch, Keyword.get(opts, :dispatch))
      |> append_present(:ref, Keyword.get(opts, :ref))

    {Plug.Cowboy, scheme: Keyword.get(opts, :scheme, :http), plug: plug, options: options}
  end

  defp append_present(options, _key, nil), do: options
  defp append_present(options, key, value), do: options ++ [{key, value}]
end
