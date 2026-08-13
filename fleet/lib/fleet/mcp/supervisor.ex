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
      case socket_files_on_disk() do
        {:ok, files} ->
          orphaned = max(files - sockets, 0)

          if orphaned > 0 do
            {:degraded,
             %{
               acceptor_supervisor: true,
               sockets: sockets,
               socket_files: sockets + orphaned,
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

  # Count exact socket files, not per-pod directories; scan failure remains explicit.
  defp socket_files_on_disk do
    base = Fleet.MCP.PodSocketSupervisor.base_dir()

    {:ok, base |> Path.join("*/sock") |> Path.wildcard() |> length()}
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
