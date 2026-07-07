defmodule Fleet.EventRouter.Listener do
  @moduledoc """
  SINGLE SOURCE of the **Cowboy child-spec** for the runtime's HTTP listeners — the "spec"
  counterpart of `Fleet.EventRouter.BindAddress` (same concern: *how a listener is exposed*).

  The runtime's three HTTP surfaces — `fleet_api` (REST + WS), `fleet_observation` (deck) and this
  app's Gitea webhook — each built the same triplet
  `BindAddress.ip()` → `options` → `{Plug.Cowboy, …}`. There is now only ONE builder: the invariant
  "loopback bind by default, exposure = named opt-in" is enforced here BY CONSTRUCTION (a
  listener routed through `cowboy_child/1` cannot forget the `:ip`; see the `BindAddress`
  moduledoc for the full security contract).

  Kept WITHIN EACH APP (local policy, not the form):

    * the **start gate** (`:start_listener` / `:start_webhooks`) — test hermeticity
      (no port bind under `mix test`) is an app choice;
    * the **port resolution** (`fetch_env!` fail-loud per-human, or webhook default) — the
      port's provenance is an app contract (see `config/runtime.exs`).

  Zero new edge: `fleet_event_router` already carries the `plug_cowboy` dep (webhook), and the
  two consumer apps (`fleet_api`, `fleet_observation`) already depend on event_router.
  """

  @doc """
  Plug.Cowboy child-spec for an HTTP listener, with the `:ip` resolved by
  `Fleet.EventRouter.BindAddress` (loopback by default; public exposure = named opt-in).

  Opts:

    * `:plug` (required) — the Plug module served.
    * `:port` (required) — TCP port, resolved by the caller (fetch_env! per-human / webhook default).
    * `:scheme` — default `:http`.
    * `:dispatch` — optional Cowboy dispatch (e.g. `fleet_api`'s WS route), passed RAW
      (not pre-compiled): Plug.Cowboy compiles it internally via `to_args/5`. An ALREADY-compiled
      dispatch would be re-compiled → decomposed segments reinterpreted as raw paths → `"ws"`
      without a slash → ArgumentError (a real PROD bug on the fleet_api side, never seen in test
      where `start_listener: false` short-circuits the bind).
    * `:ref` — optional ranch ref (several listeners of the same plug in the VM / tests).
    * `:surface_env` — name of the bind-override env var SPECIFIC to the surface (e.g.
      `LCARS_WEBHOOK_BIND_HOST`), passed to `BindAddress.ip/1`; absent → global override
      `LCARS_BIND_HOST` / loopback.
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

  # Appends `{key, value}` at the END of the list if non-nil (preserves the readable ip → port → rest order).
  defp append_present(options, _key, nil), do: options
  defp append_present(options, key, value), do: options ++ [{key, value}]
end
