defmodule Fleet.MCP.PodSocketSupervisor do
  @moduledoc """
  DynamicSupervisor of the pod-facing socket acceptors + lifecycle API for the
  spawner (seam `fleet_spawner → fleet_mcp`).

  The pod-facing transport is no longer a shared HTTP listener but a PER-POD
  AF_UNIX socket: each pod has its own (mounted inside its sole sandbox), so
  "which socket receives" = "which pod" — the identity IS the channel (cf.
  `Fleet.MCP.PodSocketAcceptor`). This DynamicSupervisor carries the fan-out (one
  acceptor per pod); it runs host-side unconditionally (nothing is created until
  a pod is provisioned).

  ## API (called by the spawner)

    * `ensure_pod_socket/1` — starts this pod's acceptor (creates the listener +
      the socket file) and returns the socket's **host path**. Idempotent: a
      re-call returns the same path without starting a duplicate. The file exists
      on return (the bwrap bind would fail otherwise).
    * `release_pod_socket/1` — stops the acceptor AND removes the socket file.
      Idempotent. The `File.rm` is MANDATORY: closing the socket frees the
      descriptor, NOT the file — without `rm` the file leaks.

  ⚠ CROSS-CONTRACT: these two functions are the REAL (default) impl of the
  `Fleet.Spawner.McpSocketProvisioner` behaviour (the contract of the seam
  `:mcp_socket_provisioner`, on the `fleet_spawner` consumer side). We keep it
  duck-typed rather than `@behaviour Fleet.Spawner.McpSocketProvisioner`: that
  compile reference would be rejected by the boundary compiler (`Fleet.Spawner`
  does not export the `McpSocketProvisioner` behaviour). Any signature change here
  MUST be mirrored onto the behaviour's `@callback`s (and vice versa).

  ## Socket path

  `<base>/<pod_id>/sock` (`base` = config `:sock_base`, default `/run/lcars/mcp`).
  The per-pod dir + the short filename keep the path under the `sun_path` limit
  (108 bytes) even for a long `pod_id` — same structure as the pods' tmux
  socket-dir (`<base>/<pod_id>/pod.sock`).
  """

  use DynamicSupervisor
  require Logger

  alias Fleet.MCP.PodSocketAcceptor

  @registry Fleet.MCP.PodSocketRegistry
  @default_base "/run/lcars/mcp"
  # AF_UNIX `sun_path` hard limit (108 incl. the NUL terminator) → the built socket path must be ≤ 107.
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
  Starts (or finds) `pod_id`'s socket acceptor and returns the host path of the
  socket file. Idempotent: if the acceptor is already running, returns the same path.
  """
  @spec ensure_pod_socket(String.t(), [String.t()]) :: {:ok, Path.t()} | {:error, term()}
  def ensure_pod_socket(pod_id, tools \\ [])
      when is_binary(pod_id) and pod_id != "" and is_list(tools) do
    if safe_pod_id?(pod_id) do
      path = socket_path(pod_id)

      # F-C138 — `tools` = the role-gated MCP tool names (derived from the cap-profile `allowedTools`),
      # threaded to the acceptor so it serves `tools/list` = base + these (single source, no bridge catalogue).
      spec = {PodSocketAcceptor, pod_id: pod_id, socket_path: path, tools: tools}

      case DynamicSupervisor.start_child(__MODULE__, spec) do
        {:ok, _pid} -> {:ok, path}
        # Already started (Registry `pod_id` key) → idempotent, same path.
        {:error, {:already_started, _pid}} -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:unsafe_pod_id, pod_id}}
    end
  end

  @doc """
  Stops `pod_id`'s acceptor and removes the socket file, then its per-pod dir. The FS results are
  discarded: a leftover socket file is visible as "file without acceptor" in
  `Fleet.MCP.Supervisor.pod_facing_status/0` (degraded) and reaped, warning-logged, by
  `sweep_stale_sockets/0` at the next boot. Idempotent.
  """
  @spec release_pod_socket(String.t()) :: :ok
  def release_pod_socket(pod_id) when is_binary(pod_id) and pod_id != "" do
    if safe_pod_id?(pod_id) do
      _ =
        case Registry.lookup(@registry, pod_id) do
          [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
          [] -> :ok
        end

      path = socket_path(pod_id)
      # Closing the socket frees the FD, NOT the file → we remove it explicitly.
      _ = File.rm(path)
      # rmdir only removes an EMPTY dir — the discarded value carries nothing: if the rm above
      # failed, the dir stays and the next boot's sweep_stale_sockets/0 reaps file + dir.
      _ = File.rmdir(Path.dirname(path))
      :ok
    else
      # A `..`/`/` pod_id would make File.rm escape the base → refuse the FS gesture (idempotent :ok).
      Logger.warning(
        "PodSocketSupervisor: release_pod_socket refused unsafe pod_id #{inspect(pod_id)} — no FS action"
      )
    end

    :ok
  end

  @doc """
  Host path of a pod's socket file: `<base>/<pod_id>/sock`.
  """
  @spec socket_path(String.t()) :: Path.t()
  def socket_path(pod_id) when is_binary(pod_id) do
    Path.join([base_dir(), pod_id, "sock"])
  end

  @doc """
  Base of the per-pod sockets (config `:sock_base`). Exposed for the
  `Fleet.MCP.Supervisor.pod_facing_status/0` probe (files-on-disk vs live acceptors).
  """
  @spec base_dir() :: Path.t()
  def base_dir, do: Application.get_env(:fleet_mcp, :sock_base, @default_base)

  @doc """
  COLD-BOOT sweep of residual per-pod socket files. A `kill -9` of the BEAM skips every `terminate/3`
  → the socket files survive on the tmpfs; a one-shot pod (non-deterministic id) never re-spawns, so
  `rm_stale` never fires on them → they linger and read as "deaf pods" (`pod_facing_status` counts a
  socket FILE without an acceptor = degraded, a false-positive FOREVER). Called ONCE per boot from
  `Fleet.MCP.Supervisor.init/1`, BEFORE this DynamicSupervisor starts → 0 live acceptor → every
  `<base>/<pod_id>/sock` is provably a residual of an earlier instance. Non-blocking (rescue → :ok).
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

  # Boundary guard: mcp owns its FS safety (a DIFFERENT concern from the pod_id GRAMMAR, whose authority
  # is `Fleet.Spawner.valid_pod_id?` — no cross-app dep here; mcp defends its OWN effect boundary, since
  # ensure/release do `File.rm` on `<base>/<pod_id>/…` and a `/` or `..` would escape it). The pod_id must
  # be ONE safe path component AND the built socket path must fit `sun_path`.
  defp safe_pod_id?(pod_id) do
    pod_id not in ["", ".", ".."] and
      not String.contains?(pod_id, ["/", "..", "\0"]) and
      byte_size(socket_path(pod_id)) <= @sun_path_max
  end
end
