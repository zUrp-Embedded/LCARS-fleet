defmodule Fleet.MCP.PodSocketSupervisor do
  @moduledoc """
  Owns per-pod AF_UNIX acceptors and socket-path cleanup.
  Repeated ensure finds the registered acceptor without updating its tool list.
  SocketWarden and the startup sweep provide separate residue cleanup paths.

  Duck-types the spawner's McpSocketProvisioner seam: its consumer-side behaviour
  cannot be imported across this boundary.
  """

  use DynamicSupervisor
  require Logger

  alias Fleet.MCP.PodSocketAcceptor

  @registry Fleet.MCP.PodSocketRegistry
  @default_base "/run/lcars/mcp"
  # AF_UNIX sun_path reserves one byte for NUL.
  @sun_path_max 107

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts or finds a pod acceptor and returns its host socket path.
  """
  @spec ensure_pod_socket(String.t(), [String.t()]) :: {:ok, Path.t()} | {:error, term()}
  def ensure_pod_socket(pod_id, tools \\ [])
      when is_binary(pod_id) and pod_id != "" and is_list(tools) do
    if safe_pod_id?(pod_id) do
      path = socket_path(pod_id)

      spec = {PodSocketAcceptor, pod_id: pod_id, socket_path: path, tools: tools}

      case DynamicSupervisor.start_child(__MODULE__, spec) do
        {:ok, _pid} -> {:ok, path}
        {:error, {:already_started, _pid}} -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:unsafe_pod_id, pod_id}}
    end
  end

  @doc """
  Requests acceptor termination and removes its socket file.
  Socket-file removal failures return release_incomplete; termination and parent-directory
  removal results are ignored. It does not terminate connection Tasks already handed off.
  Unsafe pod IDs are logged and return ok without filesystem action.
  """
  @spec release_pod_socket(String.t()) :: :ok | {:error, term()}
  def release_pod_socket(pod_id) when is_binary(pod_id) and pod_id != "" do
    if safe_pod_id?(pod_id) do
      _ = terminate_acceptor(pod_id)

      path = socket_path(pod_id)
      socket_file = remove_socket_file(path)

      _ = File.rmdir(Path.dirname(path))

      case socket_file do
        :ok -> :ok
        {:error, _} = err -> {:error, {:release_incomplete, %{socket_file: err}}}
      end
    else
      Logger.warning(
        "PodSocketSupervisor: release_pod_socket refused unsafe pod_id #{inspect(pod_id)} — no FS action"
      )

      :ok
    end
  end

  defp terminate_acceptor(pod_id) do
    case Registry.lookup(@registry, pod_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  defp remove_socket_file(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "PodSocketSupervisor: release could NOT remove socket file #{path} (#{inspect(reason)}) — " <>
            "residual socket without a Registry entry; SocketWarden (runtime) or cold-boot sweep will reap it"
        )

        {:error, reason}
    end
  end

  @doc """
  Builds a socket path without validating the pod ID; ensure/release perform that check.
  """
  @spec socket_path(String.t()) :: Path.t()
  def socket_path(pod_id) when is_binary(pod_id) do
    Path.join([base_dir(), pod_id, "sock"])
  end

  @doc """
  Configured base directory for per-pod sockets.
  """
  @spec base_dir() :: Path.t()
  def base_dir, do: Application.get_env(:lcars_fleet, :mcp_sock_base, @default_base)

  @doc """
  Pod ids with a live registered acceptor.
  """
  @spec live_pod_ids() :: [String.t()]
  def live_pod_ids do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Attempts to remove */sock paths and their parent directories.
  Call before starting acceptors: it does not distinguish live sockets from residue.
  Removal errors are ignored; rescued exceptions are logged and still return ok.
  """
  @spec sweep_stale_sockets() :: :ok
  def sweep_stale_sockets do
    base_dir()
    |> Path.join("*/sock")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      Logger.warning(
        "PodSocketSupervisor: cold-boot sweep of stale socket #{path} " <>
          "(residue of a previous instance — kill -9?)"
      )

      _ = File.rm(path)
      _ = File.rmdir(Path.dirname(path))
    end)

    :ok
  rescue
    e ->
      Logger.warning(
        "PodSocketSupervisor: cold-boot socket sweep failed (non-blocking): #{inspect(e)}"
      )

      :ok
  end

  # Filesystem and sun_path boundary; separate from the spawner's pod-id grammar.
  defp safe_pod_id?(pod_id) do
    pod_id not in ["", ".", ".."] and
      not String.contains?(pod_id, ["/", "..", "\0"]) and
      byte_size(socket_path(pod_id)) <= @sun_path_max
  end
end
