defmodule Fleet.MCP.Supervisor do
  @moduledoc """
  Supervises the MCP boot guard, per-pod acceptors, connection/publish task pools
  and mutation arbitration. The boot guard defaults to refusing undeclared boots;
  it is configuration-based (see Server), not a process-origin check.
  """

  use Supervisor

  alias Fleet.MCP.PodSocketSupervisor

  require Logger

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    # Before any acceptor exists, every socket file is cold-boot residue.
    PodSocketSupervisor.sweep_stale_sockets()

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
      PodSocketSupervisor
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
  Reports acceptor-supervisor liveness and a socket-path cross-check.
  Caught enumeration failures yield unknown. Counts and registry/path reads are
  separate observations, not an atomic snapshot or a connection-health probe.
  """
  @spec pod_facing_status() :: {:operational | :degraded | :unknown, map()}
  def pod_facing_status do
    if acceptor_supervisor_alive?() do
      # Reuse deaf_pods for the incident's subject set; do not recompute a second difference.
      with {:ok, sockets} <- active_sockets(),
           {:ok, deaf} <- deaf_pods() do
        deaf_verdict(sockets, deaf)
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
  Returns directory names with a matching */sock path but no registered acceptor.
  Does not verify file type, live pod membership or an existing connection's health.
  Caught scan/registry failures return errors; Path.wildcard does not distinguish
  every unreadable or missing directory from an empty match set.
  """
  @spec deaf_pods() :: {:ok, [String.t()]} | {:error, term()}
  def deaf_pods do
    with {:ok, on_disk} <- socket_dirs_on_disk(),
         {:ok, live} <- live_acceptor_ids() do
      {:ok, MapSet.to_list(MapSet.difference(on_disk, MapSet.new(live)))}
    end
  end

  # Treat a failed registry read as unknown; an empty fallback would mark every disk path deaf.
  defp live_acceptor_ids do
    {:ok, PodSocketSupervisor.live_pod_ids()}
  rescue
    e -> acceptor_enumeration_failed(e)
  catch
    :exit, reason -> acceptor_enumeration_failed({:exit, reason})
  end

  # Count failures must remain unknown, not an operational status with a fabricated zero.
  defp deaf_verdict(sockets, []),
    do: {:operational, %{acceptor_supervisor: true, sockets: sockets}}

  defp deaf_verdict(sockets, deaf) do
    orphaned = length(deaf)

    {:degraded,
     %{
       acceptor_supervisor: true,
       sockets: sockets,
       socket_files: sockets + orphaned,
       deaf_pods: Enum.sort(deaf),
       note: "#{orphaned} socket file(s) WITHOUT an acceptor (cascade?) — deaf pods"
     }}
  end

  defp active_sockets do
    %{active: active} = DynamicSupervisor.count_children(PodSocketSupervisor)
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

  # The parent basename identifies the incident subject; counts alone cannot name affected pods.
  defp socket_dirs_on_disk do
    base = PodSocketSupervisor.base_dir()

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
    case Process.whereis(PodSocketSupervisor) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end
end
