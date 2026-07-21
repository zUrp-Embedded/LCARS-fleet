defmodule Fleet.MCP.PodSocketSupervisor do
  @moduledoc """
  DynamicSupervisor of the pod-facing socket acceptors + lifecycle API for the
  spawner (seam `fleet_spawner → fleet_mcp`).

  The pod-facing transport is a PER-POD
  AF_UNIX socket (never a shared listener): each pod has its own (mounted inside its sole sandbox), so
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

  ## Orphan reaping (`Fleet.MCP.SocketWarden`)

  `release_pod_socket/1` runs from the pod's `terminate/3` — which a brutal kill (wedged tmux
  teardown) never reaches: the acceptor, its AF_UNIX listener, its Registry entry and the file
  would then leak until the next BEAM boot (`sweep_stale_sockets/0` only covers cold boot). The
  `SocketWarden` closes that asymmetry at RUNTIME: it reconciles the sockets it owns against the
  pods the spawner reports live, and releases the orphans (grace: 2 ticks, same doctrine as the
  PodWarden — a socket provisioned for a pod that has not registered yet is not an orphan).

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

  **Last revised**: 2026-07-21
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
  Stops `pod_id`'s acceptor and removes the socket file, then its per-pod dir. Idempotent. Returns `:ok`
  on a clean release (or a safely-refused unsafe pod_id, a no-op); a socket-file removal that FAILS is
  surfaced as `{:error, {:release_incomplete, _}}` (logged LOUD), never a blind `:ok`: the residual file
  reads as "file without acceptor" in `Fleet.MCP.Supervisor.pod_facing_status/0` (degraded) and is reaped
  by the `SocketWarden` at runtime or `sweep_stale_sockets/0` at the next boot.
  """
  @spec release_pod_socket(String.t()) :: :ok | {:error, term()}
  def release_pod_socket(pod_id) when is_binary(pod_id) and pod_id != "" do
    if safe_pod_id?(pod_id) do
      # terminate_child is :ok | {:error, :not_found} (already gone) — neither leaves a lingering
      # acceptor, so there is no failure to surface here: the residual that matters is the socket FILE.
      _ = terminate_acceptor(pod_id)

      path = socket_path(pod_id)
      # Closing the socket frees the FD, NOT the file → we remove it explicitly.
      socket_file = remove_socket_file(path)
      # rmdir only removes an EMPTY dir: if the rm above FAILED, the dir stays non-empty and rmdir fails
      # too — but that failure is already carried by `socket_file`, so the residual dir is reaped by the
      # SocketWarden (runtime) or `sweep_stale_sockets/0` (cold boot). No need to surface it twice.
      _ = File.rmdir(Path.dirname(path))

      # The release OWNS its outcome instead of always announcing `:ok`. A failed rm leaves a residual
      # socket file without a Registry entry (a false "deaf pod" to the readiness probe) → we surface it
      # (logged LOUD above) so it is not silently forgotten; the SocketWarden still reaps it at runtime.
      case socket_file do
        :ok -> :ok
        {:error, _} = err -> {:error, {:release_incomplete, %{socket_file: err}}}
      end
    else
      # A `..`/`/` pod_id would make File.rm escape the base → refuse the FS gesture. Nothing to release
      # for a malformed id (no socket was ever created under it): a SAFE no-op, honestly `:ok`.
      Logger.warning(
        "PodSocketSupervisor: release_pod_socket refused unsafe pod_id #{inspect(pod_id)} — no FS action"
      )

      :ok
    end
  end

  # Terminates the pod's acceptor if one is registered. `terminate_child` returns :ok (terminated) or
  # {:error, :not_found} (already gone) — both mean the acceptor is down; there is no "could not
  # terminate" outcome to surface (a present child is force-killed after its shutdown timeout).
  defp terminate_acceptor(pod_id) do
    case Registry.lookup(@registry, pod_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  # Removes the socket file. `:ok` on success OR already-gone (`:enoent`, idempotent); a real removal
  # failure is surfaced (LOUD) — a residual socket file without a Registry entry reads as a deaf pod.
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
  Pod ids whose acceptor is LIVE (Registry keys). The reconciliation source of the
  `Fleet.MCP.SocketWarden`: what this domain believes it is serving, to be confronted with the
  pods the spawner actually reports live.
  """
  @spec live_pod_ids() :: [String.t()]
  def live_pod_ids do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

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
  # is `Fleet.Spawner.valid_pod_id?`, a dep mcp DOES declare — but this guard is NOT that grammar: it
  # defends mcp's OWN effect boundary, since ensure/release do `File.rm` on `<base>/<pod_id>/…` and a
  # `/` or `..` would escape it, plus the built socket path must fit `sun_path`). The two coexist by
  # design (grammar vs FS/sun_path safety), NOT a copy to dodge a dependency.
  defp safe_pod_id?(pod_id) do
    pod_id not in ["", ".", ".."] and
      not String.contains?(pod_id, ["/", "..", "\0"]) and
      byte_size(socket_path(pod_id)) <= @sun_path_max
  end
end
