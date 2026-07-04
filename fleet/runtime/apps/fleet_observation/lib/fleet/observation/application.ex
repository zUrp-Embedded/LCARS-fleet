defmodule Fleet.Observation.Application do
  @moduledoc """
  Application supervisor `fleet_observation` (Ring 4 — observation deck).

  Frontière read / observabilité du core. Un listener
  Cowboy dédié sur son port (per-humain, bin/fleet_v2) sert `Fleet.Observation.Deck` (HTML LCARS +
  endpoints read JSON). Coexiste avec les autres surfaces — **on ne coupe
  rien** (ménage à la fin) :

    * `fleet_api` (le port API (per-humain), REST HMAC) — surface de **commande** ;
    * `fleet_dashboard` (`:8089`, branche sœur) — deck observation ;
    * dashboard Python v1.5 (`:8090`) — conservé en parallèle.

  ## Principe cardinal

  Le deck **ne touche pas au core** : il dépend vers le bas (lit Ring 1/2/3),
  aucune app du core ne dépend de lui. Lecture seule, intra-release, no-auth
  (frontière = isolation réseau/container, comme `fleet_api`) : il observe, il ne mute rien.

  ## Configuration

    * `:fleet_observation, :http_port` — port HTTP (posé par runtime.exs, per-humain ; absent → fail-loud,
      knob `LCARS_OBSERVATION_PORT`)
    * `:fleet_observation, :start_listener` — booléen (default `true`).
      `config/test.exs` le met à `false` (sinon `mix test` bind le port observation (per-humain)
      → crash boot umbrella — même invariant que `fleet_api`).

  ## Stratégie

  `:one_for_one` — le listener Cowboy restart `:permanent`. Le superviseur
  porte aussi `Fleet.Observation.ReadModel` (GenServer + ETS, abonné au bus) :
  le deck PODS lit `Spawner.list_pods/0` en direct, les decks event-dérivés
  lisent la projection du ReadModel.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = readmodel_children() ++ listener_children()

    # F4 (E1) : intensite 3/60 EXPLICITE (doctrine event_router/task_queue — 3/5 OTP trop serre pour un blip ; la fenetre est un CHOIX).
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60,
      name: Fleet.Observation.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  # ReadModel = abonné unique au bus. Gardé `:test` : un abonné global en test
  # = consommateur Bus parasite (interdit par l'invariant hermétique). Les tests
  # démarrent le ReadModel manuellement avec subscribe:false.
  defp readmodel_children do
    if Application.get_env(:fleet_observation, :start_readmodel, true) do
      [Fleet.Observation.ReadModel]
    else
      []
    end
  end

  @doc """
  Child specs du listener Cowboy du deck (public pour le test de bind : l'`:ip`
  est un contrat — loopback par défaut). Retourne `[]` si `:start_listener` est `false`.
  """
  def listener_children do
    if Application.get_env(:fleet_observation, :start_listener, true) do
      # Pas de défaut statique (A7) : per-humain via bin/fleet_v2 → runtime.exs ; fail-loud si absent.
      port = Application.fetch_env!(:fleet_observation, :http_port)

      # Child-spec via la source unique Fleet.EventRouter.Listener : bind loopback par défaut
      # appliqué PAR CONSTRUCTION. Le deck observe en lecture seule, no-auth (frontière =
      # isolation réseau, comme fleet_api). Un accès distant au deck passe par
      # tunnel/reverse-proxy. Exposition publique = opt-in nommé (LCARS_BIND_HOST, via BindAddress).
      [Fleet.EventRouter.Listener.cowboy_child(plug: Fleet.Observation.Deck, port: port)]
    else
      []
    end
  end
end
