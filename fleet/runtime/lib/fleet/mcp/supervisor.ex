defmodule Fleet.MCP.Supervisor do
  @moduledoc """
  Root supervisor of `fleet_mcp`: starts the system-side MCP server and the
  pod-facing socket substrate.

  Strategy `:one_for_one`, `max_restarts: 3`, `max_seconds: 60`.
  Children:
    - `Fleet.MCP.Server` (boot guard: refuses pod-side);
    - `Fleet.MCP.PodSocketRegistry` (single Registry, key = `pod_id` → acceptor);
    - `Fleet.MCP.ConnectionTaskSupervisor` (Task.Supervisor: one worker per accepted
      connection, so that `serve` runs in its own Task, never inline in the acceptor);
    - `Fleet.MCP.PodSocketSupervisor` (DynamicSupervisor of the per-pod AF_UNIX
      socket acceptors) — started unconditionally host-side (nothing is created
      as long as no pod is provisioned).

  The drive is PULL-only: the pod calls the MCP tools (`get_work_item`/`submit_result`)
  and is kicked via send-keys. Do NOT introduce push channels (a push-channel model
  was tried and abandoned). This module is the mcp DOMAIN supervisor, started
  directly by `Fleet.Application`.

  Pod-facing transport = one **AF_UNIX socket per pod** (the identity IS the channel,
  cf. `Fleet.MCP.PodSocketAcceptor`). A SHARED transport (HTTP loopback) would make
  the `pod_id` guessable across pods — the per-pod socket closes that hole by
  construction; never reintroduce a shared pod-facing transport.

  ⚠ "bridge" here means the **stdio→socket** bridge (`bin/fleet_mcp_stdio_bridge.py`),
  ALIVE (the transport drive) — there is NO PubSub bridge module in this domain.

  Containment: if `boot_environment == :pod`, `Fleet.MCP.Server.start_link/1`
  returns `{:error, :forbidden_in_pod}` → the child fails → this supervisor fails
  → `fleet_mcp` does not boot inside a pod (system-side server, outside bwrap).
  Phoenix.PubSub `Fleet.PubSub` is started by the event_router domain
  (`Fleet.EventRouter.Application`, substrate, launched by `Fleet.Application`), not started
  here (no double-start).

  **Last revised**: 2026-07-21
  """

  use Supervisor

  require Logger

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    # COLD-BOOT socket sweep BEFORE the acceptor DynamicSupervisor starts (below): any residual
    # `<base>/<pod_id>/sock` is provably from an earlier instance (kill -9 skipped terminate/3), so it
    # would read as a permanent false "deaf pod" in readiness. init/1 runs EXACTLY once per boot (this
    # sup's death = node death, parent max_restarts:0) → no re-sweep, no in-flight cascade risk.
    Fleet.MCP.PodSocketSupervisor.sweep_stale_sockets()

    children = [
      {Fleet.MCP.Server, opts},
      # Resolution Registry `pod_id → acceptor` (`:via` names), started BEFORE the
      # DynamicSupervisor that registers into it.
      {Registry, keys: :unique, name: Fleet.MCP.PodSocketRegistry},
      # Connection workers: each connection accepted on a pod socket is served in ITS own
      # Task (cf. `Fleet.MCP.PodSocketAcceptor`). Started BEFORE the DynamicSupervisor of the acceptors
      # (which `start_child`s into it as soon as a connection arrives). Without it, the acceptor served each
      # connection inline and serially → a slow handler (e.g. a forge call that hangs) froze the whole pod
      # (later connections never served → readline timeout). One Task per connection = a slow handler affects
      # only its connection. `restart: :temporary` (Task.Supervisor default): a connection that crashes dies
      # alone, without a restart.
      # max_children: FLEET-WIDE ceiling on the connection Tasks. A single pod CANNOT
      # consume it (the acceptor caps its own connections per-pod, cf. `PodSocketAcceptor`): this
      # bound is the last resort against a fleet-wide leak, not the per-pod policy.
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

  # Runtime reaper of the sockets orphaned by a brutal teardown (terminate/3 skipped): started
  # AFTER the Registry + the acceptor DynamicSupervisor it reconciles. Gated `:start_socket_warden`
  # (default true prod, false test — hermeticity: the tests drive it with explicit seams).
  defp socket_warden_child do
    if Application.get_env(:fleet_mcp, :start_socket_warden, true) do
      [Fleet.MCP.SocketWarden]
    else
      []
    end
  end

  @doc """
  LIVE state of the pod-facing substrate — `{state, detail}` for readiness
  (anti-hollow-green). Probes the REAL process (is the acceptor DynamicSupervisor
  `Fleet.MCP.PodSocketSupervisor` running?), not a config knob:

    * `:operational` — the acceptor DynamicSupervisor is alive (host-side);
      `detail.sockets` = number of active acceptors (= pod sockets).
    * `:degraded`    — either the DynamicSupervisor is absent/dead (should run
      host-side but does not), OR it is alive but a pod has a socket FILE without
      an acceptor behind it (deaf pods after an emfile cascade). Hollow-green avoided.
    * `:unknown`     — the DynamicSupervisor is alive but the on-disk socket scan
      (the deaf-pod cross-check) could not run: neither `:operational` (unverified)
      nor `:degraded` (nothing detected). The readiness caller treats it fail-closed.
  """
  @spec pod_facing_status() :: {:operational | :degraded | :unknown, map()}
  def pod_facing_status do
    if acceptor_supervisor_alive?() do
      sockets = active_sockets()

      # hollow-green — the sup can be ALIVE but EMPTY (restart after an emfile cascade:
      # the dead acceptors are recreated by nobody) while pods are waiting on them.
      # LOCAL probe (zero dep toward spawner): the socket FILES on disk survive a
      # cascade (only release_pod_socket erases them) → `files > alive acceptors` = some pods
      # have a socket-file WITHOUT an acceptor behind it = they are DEAF. Degraded, no longer operational.
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

        # The cross-check could not run → we do NOT claim :operational (unverified) and we do NOT
        # claim :degraded (nothing was detected, and a fabricated degraded would trigger a needless
        # reap). :unknown is the honest state; the readiness caller treats it fail-closed.
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

  # Socket files present under the per-pod base (created by ensure_pod_socket, erased by
  # release_pod_socket — an acceptor cascade does NOT erase them: that is the witness).
  # `{:ok, count}` of the per-pod socket FILES (`<base>/<pod_id>/sock`), NOT the entries of `base` —
  # those are the per-pod DIRECTORIES, and a stray dir or a half-provisioned pod-dir WITHOUT a `sock`
  # would inflate the count → a FALSE "orphaned socket / deaf pod" degraded reading. The glob matches
  # exactly the sockets. A FAILED scan returns `{:error, _}`, never a fabricated `0`: this scan IS the
  # deaf-pod cross-check, and collapsing a failure to `0` would read `{:operational}` (a hollow green)
  # even though the check could not run.
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
