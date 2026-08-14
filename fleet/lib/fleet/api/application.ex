defmodule Fleet.API.Application do
  @moduledoc """
  Supervises the API domain's TCP read/WebSocket listener and optional AF_UNIX
  control listener.

  `:http_port` is required when `:start_listener` is true. The TCP dispatch
  sends `/ws` to `Fleet.API.WS` and all other requests to `Fleet.API.Rest`.
  `:control_socket`, when set, adds the sole admin-write listener.
  """

  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = listener_children()

    opts = [strategy: :one_for_one, max_restarts: 3, max_seconds: 60]

    Supervisor.init(children, opts)
  end

  @doc """
  Logs build information after the root supervisor has started. Always returns
  `:ok`.
  """
  def post_boot do
    log_build_info()
    :ok
  end

  defp log_build_info do
    info = Fleet.API.BuildInfo.current()
    dirty = if info.dirty, do: "-dirty", else: ""
    require Logger

    Logger.info(
      "API: LCARS fleet — build #{info.sha}#{dirty} ref=#{info.ref} (source=#{info.source})"
    )
  end

  # `/ws` EST DEBRANCHE PAR DEFAUT DEPUIS LE 2026-08-14, ET LE MODULE EST INTACT (6-056).
  #
  # Pourquoi debranche : ce point de terminaison projette le flux d'evenements COMPLET, sans
  # authentification — un client qui ne demande rien recoit tout, y compris une CAPTURE DE L'ECRAN
  # tmux d'un pod (`wake.failed`). La posture gravee « api REST/WS no-auth by design » vaut pour de
  # l'observabilite ; elle n'a pas ete ecrite pour ca.
  #
  # Pourquoi DEBRANCHE et non SUPPRIME : personne ne le consomme — mesure du 2026-08-14, deux
  # candidats ecartes un par un. Le deck Python (`console-deck.py`, port landing) lit
  # `/api/pods` en HTTP simple, zero `ws://` dans ses 892 lignes ; le deck Elixir
  # (`Fleet.Observation`, base+1) n'a aucune WebSocket, et son propre DESIGN dit la separation :
  # « Distinct de la question API-D1 (WS /ws) — ici c'est de la lecture pure ». Mais « personne ne
  # le consomme » est une mesure sur CE depot a CET instant : une coupure REVERSIBLE dit la meme
  # chose qu'une suppression et se rend en une ligne si un consommateur se revele.
  #
  # Pour le rallumer : `config :lcars_fleet, api_serve_ws: true`. Le jour ou un dashboard le
  # demande, c'est ce commutateur qu'on bascule — et la question de ce qu'il publie se repose
  # entiere, avec `Fleet.API.WS`'s `@moduledoc` pour la poser.
  # Public (`@doc false`) parce que c'est la SEULE façon d'epingler le commutateur sans binder un
  # port : `listener_children/0` rend `[]` en `:test` (hermetisme), donc le dispatch n'y est jamais
  # construit. Un test qui allumerait le listener pour lire une route echangerait une propriete
  # contre une socket.
  @doc false
  @spec ws_route() :: [{String.t(), module(), list()}]
  def ws_route do
    if Application.get_env(:lcars_fleet, :api_serve_ws, false),
      do: [{"/ws", Fleet.API.WS, []}],
      else: []
  end

  @doc """
  Returns the configured TCP and control listener child specs, or `[]` when
  listener startup is disabled.
  """
  def listener_children do
    if Application.get_env(:lcars_fleet, :api_start_listener, true) do
      port = Application.fetch_env!(:lcars_fleet, :api_http_port)

      dispatch = [{:_, ws_route() ++ [{:_, Plug.Cowboy.Handler, {Fleet.API.Rest, []}}]}]

      tcp =
        Fleet.EventRouter.Listener.cowboy_child(
          plug: Fleet.API.Rest,
          port: port,
          dispatch: dispatch
        )

      [tcp | control_socket_child()]
    else
      []
    end
  end

  defp control_socket_child do
    case Application.get_env(:lcars_fleet, :api_control_socket) do
      sock when is_binary(sock) and sock != "" -> [Fleet.API.ControlRouter.child_spec(sock)]
      _ -> []
    end
  end
end
