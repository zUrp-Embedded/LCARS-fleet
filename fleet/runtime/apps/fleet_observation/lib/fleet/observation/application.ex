defmodule Fleet.Observation.Application do
  @moduledoc """
  Application supervisor `fleet_observation` (Ring 4 — observation deck).

  Frontière read / observabilité du core remédié (BL-026). Un listener
  Cowboy dédié sur `:8091` sert `Fleet.Observation.Deck` (HTML LCARS +
  endpoints read JSON). Coexiste avec les autres surfaces — **on ne coupe
  rien** (ménage à la fin) :

    * `fleet_api` (`:8080`, REST HMAC) — surface de **commande** ;
    * `fleet_dashboard` (`:8089`, branche sœur) — deck observation ;
    * dashboard Python v1.5 (`:8090`) — conservé en parallèle.

  ## Principe cardinal

  Le deck **ne touche pas au core** : il dépend vers le bas (lit Ring 1/2/3),
  aucune app du core ne dépend de lui. Lecture seule, no-auth, intra-release
  (ADR-C « 5-zéros »). cf. `DESIGN-observabilite.md`.

  ## Configuration

    * `:fleet_observation, :http_port` — port HTTP (default `8091`,
      knob `LCARS_OBSERVATION_PORT`)
    * `:fleet_observation, :start_listener` — booléen (default `true`).
      `config/test.exs` le met à `false` (sinon `mix test` bind `:8091`
      → crash boot umbrella — même invariant que `fleet_api`).

  ## Stratégie

  `:one_for_one` — le listener Cowboy restart `:permanent`. Incrément B =
  squelette (le deck lit `Spawner.list_pods/0` en direct). Incrément C
  ajoutera `Fleet.Observation.ReadModel` (GenServer + ETS, abonné au bus)
  sous ce superviseur, et le deck lira la projection.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = listener_children()
    opts = [strategy: :one_for_one, name: Fleet.Observation.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp listener_children do
    if Application.get_env(:fleet_observation, :start_listener, true) do
      port = Application.get_env(:fleet_observation, :http_port, 8091)

      [
        {Plug.Cowboy, scheme: :http, plug: Fleet.Observation.Deck, options: [port: port]}
      ]
    else
      []
    end
  end
end
