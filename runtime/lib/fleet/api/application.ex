defmodule Fleet.API.Application do
  @moduledoc """
  Supervises the API domain's AF_UNIX control listener — the ONLY listener this domain has.

  ## Pas de surface TCP ici, et ce n'est pas un durcissement

  Un listener TCP (REST + `/ws`) n'aurait **aucune capacite propre**, et l'inventaire porte son
  lieu :

    * les lectures d'etat (`pods`, `issues`, `workflow_runs`) ne sont pas l'autorite de ce domaine —
      elles rendraient **501** en renvoyant vers `Fleet.Observation`, qui vit sur socket ;
    * `health` / `readiness` / `version` ont un **jumeau CLI** — `fleet version` lit le MEME
      fichier (`priv/api/build_info.txt`), sans HTTP, et fonctionne fleet eteinte ;
    * les ecritures n'y transitent pas : elles vivent sur le socket de controle ci-dessous.

  Et personne ne l'appellerait : ni `bin/lcars` (qui ne parle qu'a la socket de controle), ni le
  BEAM, ni le healthcheck du conteneur, et les tests appellent le plug directement, sans reseau.

  ⚠ LE SOCKET DE CONTROLE N'EST PAS DERRIERE UN DRAPEAU DE LISTENER TCP. Imbrique dans un
  `if api_start_listener`, le chemin d'ECRITURE dependrait d'un commutateur nomme d'apres une
  surface de LECTURE. Il ne depend que de sa propre configuration — pose ou absent.
  """

  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
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

  Il n'y a pas de drapeau `:api_start_listener`. L'hermetisme des tests ne vient pas d'un
  commutateur a poser mais du fait que `config/test.exs` ne declare aucun socket de controle : rien
  a eteindre, donc rien a oublier d'eteindre. Un drapeau qui doit valoir `false` en test est une
  chose de plus qui peut valoir `true` par accident.
  """
  @spec listener_children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def listener_children, do: control_socket_child()

  defp control_socket_child do
    case Application.get_env(:lcars_fleet, :api_control_socket) do
      sock when is_binary(sock) and sock != "" -> [Fleet.API.ControlRouter.child_spec(sock)]
      _ -> []
    end
  end
end
