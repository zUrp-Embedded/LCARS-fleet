defmodule Fleet.Spawner.Pod.Backend do
  @moduledoc """
  LIFE & DEATH of a pod's OS backend — island carved out of `Fleet.Spawner.Pod`.

  The pod's OS PROCESS, end to end: the path resolvers of the launchers that start it
  (`bwrap`/`host`/`claude` — the LIFE), the launch-backend resolver, the teardown that kills it
  (BEAM Port → SIGTERM of the bwrap/host holder, or a SOCK-AWARE kill of the surviving tmux session — the
  DEATH) and the reap of an orphan before a (re)launch. The lifecycle of the per-pod MCP SOCKET NO
  LONGER lives here (refocused 2026-07-05): the whole MCP channel (socket + `.mcp-fleet.json` + env) is
  in `Pod.McpProvision`. `Pod` passes it the `state` (or a `port`/`pod_id`) as an argument; the
  module calls back NO private of `Pod` (no cycle).

  This module does NOT ORCHESTRATE: the CALLBACKS/STATES (`terminate/3`,
  `handle_event({:call, from}, :kill, ...)`, the `:releasing`/`:launching` states, the
  `do_launch_backend` fn) STAY at the heart of `Pod`; they call `Backend.*` for the OS gesture.

  ## Contract (called by `Pod`)

  - `teardown_backend(state)` — live Port → `terminate_pod_port` (SIGTERM of the holder then close;
    `Port.close` ALONE would orphan the `sleep infinity` holder); otherwise a SOCK-AWARE kill of the
    tmux session + removal of the sock-dir. Idempotent. Called by `terminate/3`,
    `handle_event({:call, from}, :kill, ...)` and the `:releasing` state.
  - `reap_orphan_pod(pod_id)` — reap of an orphan (bwrap/tmux/claude surviving a crash of the pod
    gen_statem process) of the same pod_id BEFORE a (re)launch. No-op if no orphan alive. Called by the
    `:launching` state.
  - `terminate_pod_port(port)` / `safe_port_close(port)` — **public** (tested directly): SIGTERM
    the holder's os_pid then close the Port (race `ArgumentError` absorbed). The test exercises them DIRECTLY
    via `Fleet.Spawner.Pod.Backend.terminate_pod_port/1` / `.safe_port_close/1` (no more `defdelegate`
    on the `Pod` side: direct call on the sub-module).
  - `launch_backend/0` — launch-backend resolver (`Fleet.Spawner.LaunchBackend.resolved/0`,
    single source). Called by `do_launch_backend`.
  - `bwrap_launch_path/0` / `host_launch_path/0` / `claude_launch_path/0` — path resolvers of the
    launchers (config `:fleet_spawner`). Called by the `:launching` state.

  `require Logger` (reap/teardown log). Alias `Fleet.Spawner.PodTmux` (`kill_holder`,
  `sock_path`, `alive?`); fully qualified `Fleet.Spawner.LaunchBackend` and `Application`. No
  dependency on `Fleet.Spawner.Pod` (no cycle).
  """

  require Logger

  alias Fleet.Spawner.PodTmux

  @doc """
  Reap an orphan (bwrap/tmux/claude surviving a crash of the pod gen_statem process) of the same
  pod_id before a (re)launch. Does NOTHING if no orphan alive (fresh-pod case). The kill
  (tmux kill-server + anchored pkill -f) is centralized in `PodTmux.kill_holder/1` (anti self-kill).
  Best-effort (rescue → log): a reap that raises does not block the launch.
  """
  @spec reap_orphan_pod(String.t()) :: :ok
  def reap_orphan_pod(pod_id) do
    if PodTmux.alive?(pod_id) do
      Logger.warning("pod #{pod_id}: live orphan detected before launch — reap")
      PodTmux.kill_holder(pod_id)
    end

    :ok
  rescue
    e ->
      Logger.warning("pod #{pod_id} reap_orphan failed (non-blocking): #{inspect(e)}")
      :ok
  end

  @doc """
  Teardown of the pod's backend. Live Port → `terminate_pod_port` (the SIGTERM of the bwrap holder
  brings down namespace+tmux+claude). Port already dead but bwrap/tmux/claude session surviving → SOCK-AWARE
  kill (`PodTmux.kill_holder/1`). Idempotent — called by `terminate/3` (safety net), the
  `:kill` call and the `:releasing` state; the double call is harmless.
  """
  @spec teardown_backend(map()) :: :ok
  def teardown_backend(state) do
    cond do
      is_port(state.port) and Port.info(state.port) ->
        terminate_pod_port(state.port)

      is_binary(state.tmux_session) ->
        # The bwrap pod's session (`lcars-pod-<id>`) lives on the PER-POD sock (PodTmux), NOT
        # the default tmux server. A kill targeting the default would be a silent no-op →
        # the sandboxed claude would keep consuming the OAuth. We kill via the per-pod sock
        # (same gesture as reap_orphan_pod), centralized in `PodTmux.kill_holder/1` (anti self-kill).
        PodTmux.kill_holder(state.pod_id)

      true ->
        :ok
    end

    # Remove the sock-dir AFTER the kill. The kill is reliable (both terminate_pod_port AND kill_holder kill
    # claude+namespace) → no need to keep the sock-dir "until the kill is certain". Without this
    # cleanup, the sock-dir would linger after a graceful teardown → the PodWarden would pick it up ~60s
    # later, logging a FALSE "persistent orphan" (noise that masks the real ones). The PodWarden
    # stays the safety net for the REAL orphans (pod gen_statem process crashed → teardown never ran → sock-dir + claude
    # survive → reap). Kept `tmux_session`: real pods (bwrap/host), not StubBackend (nominal sock_path,
    # rm_rf a no-op anyway).
    _ =
      if is_binary(state.tmux_session) do
        PodTmux.remove_sock_dir(state.pod_id)
      end

    :ok
  end

  @doc """
  Kills the pod (bwrap OR host chain — generic gesture). The holder (`sleep infinity`) IGNORES stdin EOF →
  `Port.close` alone ORPHANS it (the pod survives). So we SIGTERM the holder process
  by its os_pid:
  - **bwrap**: bwrap propagates to the holder → PID1 exit → namespace + tmux server + claude fall together
    (`--die-with-parent` = safety net if the BEAM dies before reaching here).
  - **host**: no namespace → the `host_launch.sh` holder traps the SIGTERM → explicit `tmux
    kill-server` on the per-pod sock (self-contained teardown; cf. `bin/host_launch.sh`).
  Port.close afterwards (frees the BEAM port). Public for direct test.
  """
  @spec terminate_pod_port(port()) :: :ok
  def terminate_pod_port(port) do
    _ =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

        _ ->
          :ok
      end

    safe_port_close(port)
  end

  @doc """
  Closes the BEAM port while absorbing the RACE `ArgumentError`: the port can close
  between our check and the close (claude finishes on its own after submit_result → its process
  exits → the port disappears). The `Port.info` guard alone is insufficient (TOCTOU) — a port
  already closed IS the desired state, so we rescue rather than crash (otherwise `:erlang.port_close`
  ArgumentError in the `:releasing` state → the pod gen_statem process would crash on a SUCCESSFUL completion).
  Public for direct test.
  """
  @spec safe_port_close(port()) :: :ok
  def safe_port_close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Resolved launch backend. Delegates to the single source (config + canonical default live in
  `Fleet.Spawner.LaunchBackend.resolved/0`) — the spawn and the readiness read the SAME resolver,
  not two copies of the default. Called by `do_launch_backend` and the `:projecting` state (MCP provisioning).
  """
  @spec launch_backend() :: module()
  def launch_backend, do: Fleet.Spawner.LaunchBackend.resolved()

  @doc """
  Path of the N0 bwrap launcher (`bwrap_launch.sh` — sandbox, default containment). Config
  `:fleet_spawner, :bwrap_launch_path`, default canonical install `/usr/local/bin/`.
  """
  @spec bwrap_launch_path() :: String.t()
  def bwrap_launch_path, do: launcher_path(:bwrap_launch_path, "bwrap_launch.sh")

  @doc """
  Path of the N0 host launcher (`host_launch.sh` — containment: none, sandbox-less sibling of
  bwrap_launch, same argv-shape). Config `:fleet_spawner, :host_launch_path`.
  """
  @spec host_launch_path() :: String.t()
  def host_launch_path, do: launcher_path(:host_launch_path, "host_launch.sh")

  @doc """
  Path of the N1 vendor launcher (`claude_launch.sh` — the vendor frontier IS this script). Config
  `:fleet_spawner, :claude_launch_path`.
  """
  @spec claude_launch_path() :: String.t()
  def claude_launch_path, do: launcher_path(:claude_launch_path, "claude_launch.sh")

  # SINGLE resolution of a launcher path: config `:fleet_spawner` (key = launcher name),
  # default = the canonical install `/usr/local/bin/<basename>` (placed by `etc/install.sh`). The three
  # publics above (API unchanged) are one-liners on top of it — a single place carries the
  # config-key → default form, not three copies to drift apart.
  defp launcher_path(config_key, default_basename) do
    Application.get_env(:fleet_spawner, config_key, "/usr/local/bin/" <> default_basename)
  end
end
