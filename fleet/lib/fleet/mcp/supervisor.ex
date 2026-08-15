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
      # Off-turn `project_publish` workers (phase-2 publish rail): a long, host-side git+filter-repo
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
      sockets = active_sockets()

      # Socket files without acceptors witness deaf pods after an acceptor cascade.
      #
      # LE STATUT ET L'INCIDENT LISENT LA MEME SOUSTRACTION. `deaf_pods/0` NOMME les sourds ; ce
      # statut n'en garde que le compte. Recalculer ici `fichiers - enfants_du_superviseur` donnerait
      # un second resultat, et un statut qui contredit l'incident qu'il accompagne est pire que pas
      # de statut : c'est celui qu'on croit parce qu'il est plus facile a lire.
      case deaf_pods() do
        {:ok, deaf} ->
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

        {:error, reason} ->
          {:unknown,
           %{
             acceptor_supervisor: true,
             sockets: sockets,
             note: "deaf-pod cross-check could not run (#{inspect(reason)}) — status unverified"
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
    with {:ok, on_disk} <- socket_dirs_on_disk() do
      {:ok, MapSet.to_list(MapSet.difference(on_disk, MapSet.new(live_acceptor_ids())))}
    end
  end

  defp live_acceptor_ids do
    Fleet.MCP.PodSocketSupervisor.live_pod_ids()
  rescue
    _ -> []
  catch
    :exit, _ -> []
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

  defp active_sockets do
    %{active: active} = DynamicSupervisor.count_children(Fleet.MCP.PodSocketSupervisor)
    active
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end
end
