defmodule Fleet.MCP.PodSocketSupervisor do
  @moduledoc """
  DynamicSupervisor des accepteurs de socket pod-facing + API de cycle de vie
  pour le spawner (seam `fleet_spawner → fleet_mcp`).

  Le transport pod-facing n'est plus un listener HTTP partagé mais une socket
  AF_UNIX PAR POD : chaque pod a la sienne (montée dans son seul sandbox), donc
  « quelle socket reçoit » = « quel pod » — l'identité est le canal (cf.
  `Fleet.MCP.PodSocketAcceptor`). Ce DynamicSupervisor porte le fan-out (un
  accepteur par pod) ; il tourne host-side inconditionnellement (rien n'est créé
  tant qu'aucun pod n'est provisionné).

  ## API (appelée par le spawner)

    * `ensure_pod_socket/1` — démarre l'accepteur de ce pod (crée le listener + le
      fichier socket) et rend le **chemin host** du socket. Idempotent : un
      re-appel rend le même chemin sans démarrer de doublon. Le fichier existe au
      retour (le bind bwrap échouerait sinon).
    * `release_pod_socket/1` — arrête l'accepteur ET retire le fichier socket.
      Idempotent. Le `File.rm` est OBLIGATOIRE : fermer le socket libère le
      descripteur, PAS le fichier — sans `rm` le fichier fuit.

  ## Chemin du socket

  `<base>/<pod_id>/sock` (`base` = config `:sock_base`, défaut `/run/lcars/mcp`).
  Le dir per-pod + le filename court tiennent le chemin sous la limite `sun_path`
  (108 octets) même pour un `pod_id` long — même structure que la socket-dir tmux
  des pods (`<base>/<pod_id>/pod.sock`).
  """

  use DynamicSupervisor

  alias Fleet.MCP.PodSocketAcceptor

  @registry Fleet.MCP.PodSocketRegistry
  @default_base "/run/lcars/mcp"

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Démarre (ou retrouve) l'accepteur de socket de `pod_id` et rend le chemin host
  du fichier socket. Idempotent : si l'accepteur tourne déjà, rend le même chemin.
  """
  @spec ensure_pod_socket(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_pod_socket(pod_id) when is_binary(pod_id) and pod_id != "" do
    path = socket_path(pod_id)
    spec = {PodSocketAcceptor, pod_id: pod_id, socket_path: path}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} -> {:ok, path}
      # Déjà démarré (clé `pod_id` du Registry) → idempotent, même chemin.
      {:error, {:already_started, _pid}} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Arrête l'accepteur de `pod_id` et retire le fichier socket (et son dir per-pod,
  best-effort). Idempotent.
  """
  @spec release_pod_socket(String.t()) :: :ok
  def release_pod_socket(pod_id) when is_binary(pod_id) and pod_id != "" do
    _ =
      case Registry.lookup(@registry, pod_id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
        [] -> :ok
      end

    path = socket_path(pod_id)
    # Fermer le socket libère le FD, PAS le fichier → on le retire explicitement.
    _ = File.rm(path)
    # Retire le dir per-pod s'il est vide (best-effort, ne casse rien sinon).
    _ = File.rmdir(Path.dirname(path))
    :ok
  end

  @doc """
  Chemin host du fichier socket d'un pod : `<base>/<pod_id>/sock`.
  """
  @spec socket_path(String.t()) :: Path.t()
  def socket_path(pod_id) when is_binary(pod_id) do
    Path.join([base(), pod_id, "sock"])
  end

  defp base, do: Application.get_env(:fleet_mcp, :sock_base, @default_base)
end
