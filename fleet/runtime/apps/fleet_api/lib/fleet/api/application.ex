defmodule Fleet.Api.Application do
  @moduledoc """
  Application supervisor `fleet_api`.

  Démarre :

    1. `Fleet.Api.RelayHandler` GenServer (subscribe Bus +
       ETS pending refs)
    2. Cowboy listener `:8080` avec dispatch :
       - `/ws` → `Fleet.Api.Ws` (WebSocket handler)
       - `/_*` → `Fleet.Api.Rest` (Plug.Router REST)

  ## Configuration

    * `:fleet_api, :http_port` — port HTTP (default `8080`)
    * `:fleet_api, :start_listener` — booléen (default `true`).
      Tests peuvent set à `false` pour démarrer Cowboy manuellement.
    * `:fleet_api, :api_secret_path` — path secret HMAC (default
      `/etc/fleet/api-secret`)
    * `:fleet_api, :git_repo_path` — racine repo config
      (default `/var/lib/lcars/config`)

  ## Stratégie

  `:one_for_one` — RelayHandler restart `:permanent`, Cowboy listener
  restart `:permanent`. Pré-enregistrement atomes events (cohérent
  ch11 M1 atom-leak DoS).
  """

  use Application

  @api_event_atoms [
    :"admin.spawn.request",
    :permission_relay_request,
    :permission_relay_response
  ]

  @impl Application
  def start(_type, _args) do
    children = base_children() ++ listener_children()

    opts = [strategy: :one_for_one, name: Fleet.Api.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Liste des atomes events `api`-related pré-enregistrés. Cohérent ch11
  M1 atom-leak DoS mitigation (Bus `String.to_existing_atom/1`).
  """
  @spec api_event_atoms() :: [atom()]
  def api_event_atoms, do: @api_event_atoms

  defp base_children do
    [Fleet.Api.RelayHandler]
  end

  defp listener_children do
    if Application.get_env(:fleet_api, :start_listener, true) do
      port = Application.get_env(:fleet_api, :http_port, 8080)

      dispatch =
        :cowboy_router.compile([
          {:_,
           [
             {"/ws", Fleet.Api.Ws, []},
             {:_, Plug.Cowboy.Handler, {Fleet.Api.Rest, []}}
           ]}
        ])

      [
        {Plug.Cowboy,
         scheme: :http, plug: Fleet.Api.Rest, options: [port: port, dispatch: dispatch]}
      ]
    else
      []
    end
  end
end
