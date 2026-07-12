defmodule Fleet.MCP.Supervisor do
  @moduledoc """
  Root supervisor of `fleet_mcp`: starts the system-side MCP server and the
  pod-facing socket substrate.

  Strategy `:one_for_one`, `max_restarts: 3`, `max_seconds: 60`.
  Children:
    - `Fleet.MCP.Server` (boot guard: refuses pod-side);
    - `Fleet.MCP.PodSocketRegistry` (single Registry, key = `pod_id` → acceptor);
    - `Fleet.MCP.ConnectionTaskSupervisor` (Task.Supervisor: one worker per accepted
      connection, so that `serve` no longer runs inline in the acceptor);
    - `Fleet.MCP.PodSocketSupervisor` (DynamicSupervisor of the per-pod AF_UNIX
      socket acceptors) — started unconditionally host-side (nothing is created
      as long as no pod is provisioned).

  The drive is PULL-only: the pod calls the MCP tools (`get_work_item`/`submit_result`)
  and is kicked via send-keys. A PUSH-channel model was tried (Anthropic Channel PoC,
  4 iterations) and abandoned — do NOT reintroduce push channels. (Scar moved here from
  the deleted `Fleet.MCP.Application` wrapper at the Z2 collapse, 2026-07-12 — this
  module is now the mcp DOMAIN supervisor, started directly by `Fleet.Application`.)

  Pod-facing transport = one **AF_UNIX socket per pod** (the identity IS the channel,
  cf. `Fleet.MCP.PodSocketAcceptor`). The former shared HTTP loopback transport
  (`PodTools` in `transport: :http`, Plug.Cowboy/Ranch, `:pod_facing_port`) is
  REMOVED: it was shared by all pods, so the `pod_id` was guessable there
  (hence the old capability). The per-pod socket closes that hole by construction.

  `Fleet.MCP.Bridge` (PubSub↔channels bridge) stays REMOVED (dead husk). ⚠ "bridge"
  is a homonym: the **stdio→socket** bridge (`bin/fleet_mcp_stdio_bridge.py`) is
  ALIVE (transport drive), nothing to do with this dead `Fleet.MCP.Bridge` PubSub.

  Containment: if `boot_environment == :pod`, `Fleet.MCP.Server.start_link/1`
  returns `{:error, :forbidden_in_pod}` → the child fails → this supervisor fails
  → `fleet_mcp` does not boot inside a pod (system-side server, outside bwrap).
  Phoenix.PubSub `Fleet.PubSub` is started by the event_router domain
  (`Fleet.EventRouter.Application`, Ring 0, launched by `Fleet.Application`), not started
  here (no double-start).
  """

  use Supervisor

  require Logger

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
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
      # max_children: a pod bridge that leaks its connections can no longer accumulate tasks+fds
      # without bound — the accept loop receives {:error, :max_children} and refuses the excess connection.
      {Task.Supervisor, name: Fleet.MCP.ConnectionTaskSupervisor, max_children: 32},
      Fleet.MCP.PodSocketSupervisor
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
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
  """
  @spec pod_facing_status() :: {:operational | :degraded, map()}
  def pod_facing_status do
    if acceptor_supervisor_alive?() do
      sockets = active_sockets()

      # hollow-green — the sup can be ALIVE but EMPTY (restart after an emfile cascade:
      # the dead acceptors are recreated by nobody) while pods are waiting on them.
      # LOCAL probe (zero dep toward spawner): the socket FILES on disk survive a
      # cascade (only release_pod_socket erases them) → `files > alive acceptors` = some pods
      # have a socket-file WITHOUT an acceptor behind it = they are DEAF. Degraded, no longer operational.
      orphaned = max(socket_files_on_disk() - sockets, 0)

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
    else
      {:degraded, %{acceptor_supervisor: false, note: "PodSocketSupervisor not alive"}}
    end
  end

  # Socket files present under the per-pod base (created by ensure_pod_socket, erased by
  # release_pod_socket — an acceptor cascade does NOT erase them: that is the witness).
  defp socket_files_on_disk do
    base = Fleet.MCP.PodSocketSupervisor.base_dir()

    # Count the actual per-pod socket FILES (`<base>/<pod_id>/sock`), NOT the entries of `base` — those
    # are the per-pod DIRECTORIES, and a stray dir or a half-provisioned pod-dir WITHOUT a `sock` would
    # inflate the count → a FALSE "orphaned socket / deaf pod" degraded reading (SOC-EFF-005). The glob
    # matches exactly the sockets.
    base
    |> Path.join("*/sock")
    |> Path.wildcard()
    |> length()
  rescue
    e ->
      # The socket scan IS the deaf-pod / orphaned-socket cross-check. Collapsing a FAILED scan to `0`
      # yields `orphaned = max(0 - sockets, 0) = 0` → an `{:operational, …}` (green) reading even though
      # the check could NOT run — a hollow green. We keep `0` (a fabricated `:degraded` would be worse), but
      # LOUD: the operator must know the cross-check was blind this tick.
      Logger.warning(
        "MCP.Supervisor: on-disk socket-file scan FAILED (#{inspect(e)}) — deaf-pod cross-check could " <>
          "not run, treating on-disk sockets as 0 (status may read operational without verification)"
      )

      0
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
