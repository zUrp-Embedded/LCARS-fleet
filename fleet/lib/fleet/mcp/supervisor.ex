defmodule Fleet.MCP.Supervisor do
  @moduledoc """
  Root supervisor for the system-side MCP server and pod-facing socket substrate.
  Per-pod AF_UNIX channels bind identity outside the wire; a bounded Task pool
  isolates connections, while idempotency collapses concurrent mutation retries.
  Server containment makes pod-side boot fail closed.
  """

  use Supervisor

  require Logger

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    # Before any acceptor exists, every socket file is cold-boot residue.
    Fleet.MCP.PodSocketSupervisor.sweep_stale_sockets()

    children = [
      {Fleet.MCP.Server, opts},
      # Mutation single-flight precedes connection workers.
      Fleet.MCP.Idempotency,
      {Registry, keys: :unique, name: Fleet.MCP.PodSocketRegistry},
      # Acceptors add temporary workers here; their own limit protects this fleet-wide ceiling.
      {Task.Supervisor, name: Fleet.MCP.ConnectionTaskSupervisor, max_children: 32},
      # Off-turn `project_publish` workers: a long, host-side git+filter-repo
      # job the tool call must not block on. A separate pool so a slow publish never starves the
      # connection tasks above; the small cap bounds concurrent history rewrites.
      {Task.Supervisor, name: Fleet.MCP.PublishTaskSupervisor, max_children: 4},
      Fleet.MCP.PodSocketSupervisor
    ]

    children = children ++ socket_warden_child()

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end

  # Tests disable the runtime reaper and drive its seams explicitly.
  defp socket_warden_child do
    if Application.get_env(:lcars_fleet, :mcp_start_socket_warden, true) do
      [Fleet.MCP.SocketWarden]
    else
      []
    end
  end

  @doc """
  Returns readiness from the live acceptor supervisor plus its on-disk socket
  cross-check. Scan failure is `:unknown`, never a hollow operational state.
  """
  @spec pod_facing_status() :: {:operational | :degraded | :unknown, map()}
  def pod_facing_status do
    if acceptor_supervisor_alive?() do
      # Socket files without acceptors witness deaf pods after an acceptor cascade.
      #
      # LE STATUT ET L'INCIDENT LISENT LA MEME SOUSTRACTION. `deaf_pods/0` NOMME les sourds ; ce
      # statut n'en garde que le compte. Recalculer ici `fichiers - enfants_du_superviseur` donnerait
      # un second resultat, et un statut qui contredit l'incident qu'il accompagne est pire que pas
      # de statut : c'est celui qu'on croit parce qu'il est plus facile a lire.
      #
      # ⚠ LES DEUX LECTURES PEUVENT ECHOUER, ET AUCUNE NE REND UN CHIFFRE PLAUSIBLE QUAND ELLE
      # ECHOUE. C'est le contrat annonce par le `@moduledoc` de cette fonction — « scan failure is
      # `:unknown`, never a hollow operational state » — et il ne tenait que pour l'une des deux.
      with {:ok, sockets} <- active_sockets(),
           {:ok, deaf} <- deaf_pods() do
        orphaned = length(deaf)

        if orphaned > 0 do
          {:degraded,
           %{
             acceptor_supervisor: true,
             sockets: sockets,
             socket_files: sockets + orphaned,
             deaf_pods: Enum.sort(deaf),
             note: "#{orphaned} socket file(s) WITHOUT an acceptor (cascade?) — deaf pods"
           }}
        else
          {:operational, %{acceptor_supervisor: true, sockets: sockets}}
        end
      else
        {:error, reason} ->
          {:unknown,
           %{
             acceptor_supervisor: true,
             note:
               "pod-facing cross-check could not run (#{inspect(reason)}) — status unverified. " <>
                 "Aucun compte n'est rendu ici : un chiffre issu d'une lecture qui a echoue se lit " <>
                 "comme une mesure"
           }}
      end
    else
      {:degraded, %{acceptor_supervisor: false, note: "PodSocketSupervisor not alive"}}
    end
  end

  @doc """
  Pod ids holding a socket file with NO acceptor behind it — deaf pods.

  A pod reaches its socket through a path, not through a process: when its acceptor dies (a
  `:one_for_one` cascade, a crash storm hitting `max_restarts`), the file stays and the pod keeps
  writing into it. Nothing on the pod's side reports an error, so this is the failure mode that
  looks exactly like silence.

  `{:error, reason}` when the scan itself could not run — an unreadable directory is NOT an empty
  one, and answering `[]` there would clear pods this function cannot see.
  """
  @spec deaf_pods() :: {:ok, [String.t()]} | {:error, term()}
  def deaf_pods do
    with {:ok, on_disk} <- socket_dirs_on_disk(),
         {:ok, live} <- live_acceptor_ids() do
      {:ok, MapSet.to_list(MapSet.difference(on_disk, MapSet.new(live)))}
    end
  end

  # ⚠ CETTE FONCTION RENDAIT `[]` SUR ECHEC, ET C'ETAIT L'INVARIANT DU `@doc` CI-DESSUS APPLIQUE A
  # UNE SEULE MOITIE. Il dit : « an unreadable directory is NOT an empty one, and answering `[]`
  # there would clear pods this function cannot see ». La meme phrase vaut pour l'autre operande, en
  # sens inverse : un superviseur injoignable n'est pas un superviseur SANS acceptor, et repondre
  # `[]` ici declare SOURDS tous les pods du disque — `difference(on_disk, [])` vaut `on_disk`.
  #
  # Le warden ne tue pas un pod sourd (il refuse de reparer, deliberement), mais il ouvre un
  # incident `pod.deaf` par pod apres confirmation sur deux ticks, avec issue sysadmin a la
  # recurrence. Une panne du superviseur d'acceptors produisait donc une alarme de masse, au moment
  # precis ou le signal reel comptait le plus.
  #
  # Le chemin d'erreur EXISTAIT DEJA : le `@spec` autorise `{:error, term()}`, et
  # `SocketWarden.report_deaf_pods/1` traite `:error` par « on ne blanchit personne ». Seul cet
  # operande ne s'en servait pas.
  defp live_acceptor_ids do
    {:ok, Fleet.MCP.PodSocketSupervisor.live_pod_ids()}
  rescue
    e -> acceptor_enumeration_failed(e)
  catch
    :exit, reason -> acceptor_enumeration_failed({:exit, reason})
  end

  # `count_children` sur un superviseur vivant ne devrait pas echouer — mais « ne devrait pas » est
  # exactement ce que ce module refuse ailleurs : un `0` rendu par une lecture cassee est
  # indiscernable d'un `0` mesure, et il ferait rendre `:operational` a un statut aveugle.
  defp active_sockets do
    %{active: active} = DynamicSupervisor.count_children(Fleet.MCP.PodSocketSupervisor)
    {:ok, active}
  rescue
    e -> acceptor_enumeration_failed(e)
  catch
    :exit, reason -> acceptor_enumeration_failed({:exit, reason})
  end

  defp acceptor_enumeration_failed(reason) do
    Logger.warning(
      "MCP.Supervisor: acceptor enumeration FAILED (#{inspect(reason)}) — pod-facing status = " <>
        ":unknown and NO deaf-pod verdict is issued (fail-closed: answering an empty set here " <>
        "would declare every pod on disk deaf)"
    )

    {:error, {:acceptor_enumeration, reason}}
  end

  # Le repertoire porte le pod_id — c'est `PodSocketSupervisor.socket_path/1` qui le pose. On rend
  # donc les NOMS et non un compte : un compte dit qu'il y a des sourds, il ne dit pas lesquels, et
  # un incident sans sujet n'est pas actionnable.
  defp socket_dirs_on_disk do
    base = Fleet.MCP.PodSocketSupervisor.base_dir()

    ids =
      base
      |> Path.join("*/sock")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
      |> MapSet.new()

    {:ok, ids}
  rescue
    e ->
      Logger.warning(
        "MCP.Supervisor: on-disk socket-file scan FAILED (#{inspect(e)}) — deaf-pod cross-check could " <>
          "not run; status = :unknown (fail-closed, never a hollow :operational)"
      )

      {:error, e}
  end

  defp acceptor_supervisor_alive? do
    case Process.whereis(Fleet.MCP.PodSocketSupervisor) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end
end
