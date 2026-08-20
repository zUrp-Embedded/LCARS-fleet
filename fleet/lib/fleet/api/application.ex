defmodule Fleet.API.Application do
  @moduledoc """
  Supervises the API domain's AF_UNIX control listener — the ONLY listener this domain has.

  ## Il n'y a plus de surface TCP, et ce n'est pas un durcissement

  Ce domaine servait aussi un listener TCP (`Fleet.API.Rest` + `/ws`). Il a ete retire le
  2026-08-14 parce qu'il n'avait **aucune capacite propre**, et la mesure porte son lieu :

    * les lectures d'etat (`pods`, `issues`, `workflow_runs`) rendaient **501** en renvoyant vers
      `Fleet.Observation` — ce n'etait pas son autorite, et son message de renvoi nommait un port
      (`deck :8091`) mort depuis que l'observation est passee sur socket ;
    * `/ws` etait deja debranche (coupure reversible du 2026-08-14, meme journee) ;
    * `health` / `readiness` / `version` ont un **jumeau CLI** — `fleet_v2 version` lit le MEME
      fichier (`priv/api/build_info.txt`), sans HTTP, et fonctionne fleet eteinte ;
    * les ecritures n'ont jamais transite par la : elles vivent sur le socket de controle ci-dessous.

  Et **personne ne l'appelait** : ni `bin/lcars` (son propre commentaire dit que `$API_URL` n'est
  lu nulle part), ni le BEAM, ni le healthcheck du conteneur (qui teste le port 22), et les tests
  appelaient le plug directement, sans reseau.

  ⚠ LE SOCKET DE CONTROLE N'EST PLUS DERRIERE UN DRAPEAU DE LISTENER TCP. Il etait imbrique dans
  `if api_start_listener` : le chemin d'ECRITURE dependait donc d'un commutateur nomme d'apres une
  surface de LECTURE. Il ne depend plus que de sa propre configuration — pose ou absent.
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
  @spec post_boot() :: :ok
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

  @doc """
  Child spec of the control listener, or `[]` when no control socket is configured.

  ## L'absence de configuration EST l'interrupteur

  Il n'y a plus de drapeau `:api_start_listener`. L'hermetisme des tests ne vient plus d'un
  commutateur a poser mais du fait que `config/test.exs` ne declare aucun socket de controle : rien
  a eteindre, donc rien a oublier d'eteindre. Un drapeau qui doit valoir `false` en test est une
  chose de plus qui peut valoir `true` par accident.
  """
  def listener_children, do: control_socket_child()

  defp control_socket_child do
    case Application.get_env(:lcars_fleet, :api_control_socket) do
      sock when is_binary(sock) and sock != "" -> [Fleet.API.ControlRouter.child_spec(sock)]
      _ -> []
    end
  end
end
