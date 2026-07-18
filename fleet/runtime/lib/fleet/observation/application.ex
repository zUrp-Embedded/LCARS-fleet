defmodule Fleet.Observation.Application do
  @moduledoc """
  Superviseur de domaine (ex-callback Application de l'app umbrella — collapse Z2
  migration 2026-07-12 ; nom conservé pour zéro churn de références).

  Domain supervisor `fleet_observation` (surface — observation deck).

  Read / observability frontier of the core. A dedicated
  Cowboy listener on its port (per-human, bin/fleet_v2) serves `Fleet.Observation.Deck` (LCARS HTML +
  JSON read endpoints). Coexists with the other surfaces — **we cut off
  nothing** (cleanup at the end):

    * `fleet_api` (the API port (per-human), no-auth by design) — **command** surface.

  ## Cardinal principle

  The deck **does not touch the core**: it depends downward (bus
  `fleet_event_router` + catalogue `fleet_cap_profile`; `fleet_spawner`
  for `list_pods/0`), no core app depends on it. Read-only, intra-release, no-auth
  (frontier = network/container isolation, like `fleet_api`): it observes, it mutates nothing.

  ## Configuration

    * `:fleet_observation, :http_port` — HTTP port (set by runtime.exs, per-human; absent → fail-loud,
      knob `LCARS_OBSERVATION_PORT`)
    * `:fleet_observation, :start_listener` — boolean (default `true`).
      `config/test.exs` sets it to `false` (otherwise `mix test` binds the observation port (per-human)
      → umbrella boot crash — same invariant as `fleet_api`).

  ## Strategy

  `:one_for_one` — the Cowboy listener restarts `:permanent`. The supervisor
  also carries `Fleet.Observation.ReadModel` (GenServer + ETS, subscribed to the bus):
  the PODS deck reads `Spawner.list_pods/0` live, the event-derived decks
  read the ReadModel's projection.

  **Last revised**: 2026-07-18
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = readmodel_children() ++ listener_children()

    # F4 (E1): 3/60 intensity EXPLICIT (event_router/task_queue doctrine — OTP's 3/5 too tight for a blip; the window is a CHOICE).
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    ]

    Supervisor.init(children, opts)
  end

  # ReadModel = sole bus subscriber. Guarded in `:test`: a global subscriber in test
  # = parasitic Bus consumer (forbidden by the hermetic invariant). Tests
  # start the ReadModel manually with subscribe:false.
  defp readmodel_children do
    if Application.get_env(:fleet_observation, :start_readmodel, true) do
      [Fleet.Observation.ReadModel]
    else
      []
    end
  end

  @doc """
  Child specs of the deck's Cowboy listener (public for the bind test: the `:ip`
  is a contract — loopback by default). Returns `[]` if `:start_listener` is `false`.
  """
  def listener_children do
    if Application.get_env(:fleet_observation, :start_listener, true) do
      # No static default (A7): per-human via bin/fleet_v2 → runtime.exs; fail-loud if absent.
      port = Application.fetch_env!(:fleet_observation, :http_port)

      # Child-spec via the single source Fleet.EventRouter.Listener: loopback bind by default
      # applied BY CONSTRUCTION. The deck observes read-only, no-auth (frontier =
      # network isolation, like fleet_api). Remote access to the deck goes through
      # a tunnel/reverse-proxy. Public exposure = named opt-in (LCARS_BIND_HOST, via BindAddress).
      [Fleet.EventRouter.Listener.cowboy_child(plug: Fleet.Observation.Deck, port: port)]
    else
      []
    end
  end
end
