defmodule Fleet.Spawner.Pod.McpProvision do
  @moduledoc """
  The pod↔fleet MCP CHANNEL, end to end — island extracted from `Fleet.Spawner.Pod`.

  The `fleet` MCP server is the SOLE pod↔fleet comm channel (never scraping). This module
  carries the WHOLE channel (recentered 2026-07-05 — the socket lifecycle lived in `Pod.Backend`,
  the "OS process life & death" module, where it was an orphan concern):

  - the **per-pod AF_UNIX SOCKET**: `ensure_pod_socket/1` (creation before launch) /
    `release_pod_socket/1` (release at terminate) via the RUNTIME SEAM
    `:mcp_socket_provisioner`;
  - the **`.mcp-fleet.json`** (`alwaysLoad:true`) that claude loads at boot + the copy of the stdio
    bridge (`fleet_mcp_bridge.py`) INTO the pod (`maybe_provision_mcp_config/5`);
  - the pod process's **MCP env vars** (`mcp_channel_env/2`).

  The module does NOT read the Pod's `state` and calls back NO Pod private — the Pod resolves the
  placement (`pod_dir`, `sandbox_home`) and the backend, then passes these values as arguments. No
  state mutation, no Port, no timer.

  ## Contract (called by `Pod`)

  - `ensure_pod_socket/1` — state `:projecting`, BEFORE the launch (the socket file MUST exist
    before the bwrap bind) → `{:ok, socket_path}` (host path).
  - `maybe_provision_mcp_config/5` — inside the `with` of the `:projecting` state. Returns
    `:ok` (StubBackend with no spec, or a successful write) | `{:error, {:mcp_server_spec_required, backend}}`
    (REAL backend with no spec, fail-loud) | `{:error, reason}` (FS failure: `{:write_failed, …}` /
    `{:mcp_bridge_provision_failed, …}`). The error is propagated to the `with` → `transition_failed`.
  - `mcp_channel_env/2` — the pod process's MCP env vars to merge into the launch env (state `:launching`).
  - `release_pod_socket/1` — the `after` of `terminate/3` (self-protected, NEVER raises).

  The MCP server spec is read from config (`:fleet_spawner, :mcp_server_spec`); the resolved backend
  is passed by the Pod (single source `Fleet.Spawner.LaunchBackend.resolved/0`).
  """

  require Logger

  alias Fleet.Spawner.McpSocketProvisioner
  alias Fleet.Spawner.Pod.Fs

  # RUNTIME SEAM of the per-pod MCP socket provisioner. The CONTRACT (typed callbacks, why
  # no compile dep fleet_spawner → fleet_mcp, which impls) lives in the behaviour
  # `Fleet.Spawner.McpSocketProvisioner`; `resolved/0` is there the SINGLE SOURCE of the default
  # (`Fleet.MCP.PodSocketSupervisor` in prod, `Fleet.Spawner.MCPSocketStub` set by config/test.exs).
  defp mcp_socket_provisioner, do: McpSocketProvisioner.resolved()

  # The seam is DUCK-TYPED and stays INJECTED post-collapse (Z5, 2026-07-13) : this is THE assumed
  # upward runtime seam — mcp already declares Fleet.Spawner (boundary dep, Delegation), so
  # spawner→mcp as a literal call would close a boundary CYCLE (forbidden by the compiler; and
  # doctrinally the core must not compile-depend on its own substrate consumer). So a
  # misconfigured `:mcp_socket_provisioner` (a module that does not export the callbacks) would make
  # `apply/3` raise `UndefinedFunctionError` deep in `:projecting` → crash the pod gen_statem with an
  # obscure error. Guard with `function_exported?` → a typed `{:error, {:mcp_provisioner_misconfigured,
  # mod}}` the caller folds onto `transition_failed`, a CLEAR deploy-error message.
  defp conforming_provisioner do
    mod = mcp_socket_provisioner()

    # Side-effect only (trigger load); the real check is `function_exported?` below → discard explicitly.
    _ = Code.ensure_loaded(mod)

    if function_exported?(mod, :ensure_pod_socket, 2) and
         function_exported?(mod, :release_pod_socket, 1) do
      {:ok, mod}
    else
      {:error, {:mcp_provisioner_misconfigured, mod}}
    end
  end

  @doc """
  ENSURE (state `:projecting`, before the launch): creates the listener + the socket file of THIS pod
  (idempotent on the central side) and returns `{:ok, socket_path}` (host path). The file MUST exist
  before the bwrap bind — a failure is propagated to the `with` → `transition_failed`.
  """
  @spec ensure_pod_socket(String.t(), [String.t()]) :: {:ok, Path.t()} | {:error, term()}
  def ensure_pod_socket(pod_id, tools \\ []) when is_binary(pod_id) and is_list(tools) do
    with {:ok, mod} <- conforming_provisioner() do
      # F-C138 — `tools` = the pod's role-gated MCP tool names (from the cap-profile `allowedTools`),
      # threaded to the central acceptor so it serves `tools/list` = base + these (single source).
      apply(mod, :ensure_pod_socket, [pod_id, tools])
    end
  end

  @doc """
  RELEASE (`terminate/3` safety net, `after` clause): stops the listener AND removes the socket file
  (idempotent on the central side). Self-protected (rescue/catch → log, returns `:ok`): it runs in
  the `after` of `terminate`, a raise there would propagate and mask the stop reason. Clause
  `_state` (pod_id absent) = no-op.
  """
  @spec release_pod_socket(map()) :: :ok
  def release_pod_socket(%{pod_id: pod_id}) when is_binary(pod_id) do
    case conforming_provisioner() do
      {:ok, mod} ->
        _ = apply(mod, :release_pod_socket, [pod_id])

      {:error, reason} ->
        Logger.warning("pod #{pod_id} release_pod_socket skipped — #{inspect(reason)}")
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "pod #{pod_id} release_pod_socket raised (non-fatal) — #{Exception.message(e)}"
      )

      :ok
  catch
    kind, value ->
      Logger.warning("pod #{pod_id} release_pod_socket #{kind} (non-fatal) — #{inspect(value)}")
      :ok
  end

  def release_pod_socket(_state), do: :ok

  # fleet MCP server (SOLE pod↔fleet comm channel; never scraping).
  # Config = pod-accessible path (outside /home,/tmp, like bwrap/claude_launch). A REAL
  # pod speaks MCP, period — there is NO alternative file mode. `nil` is legitimate ONLY for
  # launch-stub tests (claude not launched); a real backend (LauncherPortBackend) with no MCP spec is a
  # config bug (the brief instructs submit_result, impossible without a server).
  #
  # ONE parameterized mechanism: the config supplies the server spec (`command`/`args`/`env`),
  # we force `alwaysLoad` on it. The spec decides — PROD: stdio→central bridge via a per-pod AF_UNIX socket
  # (path set per-pod in `LCARS_FLEET_MCP_SOCKET`), TESTS: file-backed fixture. Same mechanism, different spec.
  defp mcp_server_spec, do: Application.get_env(:fleet_spawner, :mcp_server_spec)

  @doc """
  Is the MCP server spec configured (`:fleet_spawner, :mcp_server_spec`)? PUBLIC accessor =
  SINGLE SOURCE of this read for cross-app probes (`Fleet.API.Readiness`): they delegate
  to the key's owner instead of re-reading `Application.get_env(:fleet_spawner, …)` (implicit
  coupling to the key name → silent `nil` if the key is renamed). Same pattern as
  `Fleet.Spawner.LaunchBackend.resolved/0`.
  """
  @spec server_spec_present?() :: boolean()
  def server_spec_present?, do: not is_nil(mcp_server_spec())

  @doc """
  MCP env vars to propagate to the pod (consumed by bridge.py on the pod side). `LCARS_POD_ID` is ALWAYS
  set: needed so that bridge.py injects `_lcars_pod_id` into every MCP tool call
  (correlation on the central PodTools side, TaskQueue.next_for filtering). Without it the pod is anonymous —
  get_work_item would return ONLY the untargeted ones (misses the tasks targeted via wake_pod).

  `LCARS_ROLE` (= the cap-profile's `metadata.name` = business role): bridge.py injects it as
  `_lcars_role`. This wire field is INDICATIVE (the pod's tool surface, descriptive), NOT the
  source of the role-token decision: `PodTools.create_issue` resolves the role from the SPAWN
  (`pod_id → role` engraved on the server side, `Fleet.Spawner.pod_info`), not from the wire (unauthenticated →
  spoofing). Set HERE (the pod process's env) → covers host_launch AND bwrap (which re-`--setenv`s it
  in its sandbox).

  No more `LCARS_POD_CAPABILITY`: the pod's identity is no longer a secret presented on the wire but
  the CHANNEL itself — each pod has its AF_UNIX MCP socket (mounted in its sole sandbox) → "which
  socket receives" = "which pod" (cf. `Fleet.MCP.PodSocketAcceptor`). The path of this socket
  travels in `LCARS_FLEET_MCP_SOCKET` in the MCP SERVER's env (`build_fleet_mcp_entry`), not here
  (the claude pod process's env).
  """
  @spec mcp_channel_env(String.t(), String.t() | nil) :: %{String.t() => String.t()}
  def mcp_channel_env(pod_id, role) when is_binary(pod_id) do
    base = %{"LCARS_POD_ID" => pod_id}
    if is_binary(role) and role != "", do: Map.put(base, "LCARS_ROLE", role), else: base
  end

  @doc """
  Writes `<pod_dir>/.mcp-fleet.json` (+ copies the stdio bridge into the pod). `backend` is resolved
  by the Pod (`Fleet.Spawner.LaunchBackend.resolved/0`) and passed here; the server spec is read from
  config. `socket_path` = host path of the per-pod MCP socket (returned by `ensure_pod_socket/1`,
  state `:projecting`); set as-is in the server's `LCARS_FLEET_MCP_SOCKET` (host == namespace,
  cf. `build_fleet_mcp_entry`). Returns `:ok` (StubBackend with no spec, or a successful write) |
  `{:error, {:mcp_server_spec_required, backend}}` (REAL backend with no spec, fail-loud) |
  `{:error, reason}` FS — propagated to the `:projecting` `with` → `transition_failed`.
  """
  @spec maybe_provision_mcp_config(Path.t(), Path.t(), String.t(), Path.t(), module()) ::
          :ok | {:error, term()}
  def maybe_provision_mcp_config(pod_dir, sandbox_home, pod_id, socket_path, backend) do
    case {mcp_server_spec(), backend} do
      # Explicit test seam: StubBackend does not launch claude → no MCP required.
      {nil, Fleet.Spawner.LaunchBackend.StubBackend} ->
        :ok

      # A REAL backend with no MCP spec is a config bug — the real pod speaks MCP
      # (the brief instructs submit_result, impossible without a server). A clean refusal
      # (propagated to the :projecting state's with → transition_failed) that makes the faulty state
      # unrepresentable, rather than a pod launched then wedged in a silent timeout.
      {nil, backend} ->
        {:error, {:mcp_server_spec_required, backend}}

      {spec, _backend} when is_map(spec) ->
        # Non-bang + return {:ok|:error} propagated to the with chain of the `:projecting` state
        # (where the error triggers transition_failed cleanly).
        with {:ok, fleet_entry} <-
               build_fleet_mcp_entry(spec, pod_dir, sandbox_home, pod_id, socket_path) do
          config = %{"mcpServers" => %{"fleet" => fleet_entry}}

          Fs.safe_write(
            Path.join(pod_dir, ".mcp-fleet.json"),
            Jason.encode!(config, pretty: true)
          )
        end
    end
  end

  # Builds the `fleet` MCP server entry of the `.mcp-fleet.json`, provisioning
  # the stdio bridge INTO the pod_dir.
  #
  # The bwrap is a SANCTUARY — it mounts only
  # `/usr`, `/etc`, `/sys`, `$POD_DIR`, `$GIT_MIRROR`, the vendor and the sock-dir.
  # `/var/lib/lcars` is NOT mounted there. Launching the bridge via its HOST path
  # (`/var/lib/lcars/bin/...py`) with a log under `/var/lib/lcars/` would fail:
  # INSIDE the sandbox that path does not exist → `bash -c` fails → the `fleet` MCP
  # server never starts → the `mcp__fleet__get_work_item` tool is never loaded
  # → the agent improvises curl and times out. (Such a bridge works in a direct test
  # because it runs on the HOST, not in the sandbox.)
  #
  # On the N1 side (the provisioning): `bwrap_launch.sh` stays MCP-agnostic (N0).
  # We copy the bridge under `pod_dir/.lcars/` and resolve the spec's
  # `{{BRIDGE}}`/`{{BRIDGE_LOG}}` placeholders.
  #
  # ⚠ Relocation trap: setting the HOST path (`pod_dir = /home/<human>/pods/pod_<id>`) in
  # the `.mcp-fleet.json` would break as soon as bwrap RELOCATES the pod_dir behind `/home/.pod`
  # (`sandbox_home`) → the host path NO LONGER EXISTS in the namespace → `bash -c "exec python3 <host>.py
  # 2>><host>.log"` would abort at the redirect (parent dir absent) BEFORE exec'ing python → the `fleet`
  # MCP server never up → 0 `mcp__fleet__*` tool. Hence TWO distinct paths: the bridge is COPIED to the
  # HOST path (where the spawner writes), but the `.mcp-fleet.json` references the IN-NAMESPACE path
  # (`sandbox_home/.lcars/…`, what claude executes in the sandbox). Host pods (containment none):
  # `sandbox_home == pod_dir` → identity (strict backward compat). Without this separation, a bwrap
  # pod would have no `mcp__fleet__*` tool (the bridge would never start) — hence no way to
  # pull its brief nor to submit its result.
  #
  # Injects `LCARS_POD_ID` AND `LCARS_FLEET_MCP_SOCKET` into the server's env (the bridge reads them to
  # correlate `get_work_item` to the right pod AND to know ON WHICH socket to talk to the central; do not depend on
  # claude→bridge env inheritance) and forces `alwaysLoad:true` (otherwise the MCP tools are deferred behind
  # ToolSearch, absent from the turn-1 prompt).
  #
  # ⚠ Host vs namespace for the SOCKET: unlike the bridge (host_bridge for the copy, ns_bridge for
  # the argv), the `socket_path` is set AS-IS. The bwrap bind will mount the socket at the SAME absolute path
  # (`--bind X X`) → host == namespace → NO remap. (Host pods, containment none: no namespace at
  # all, the host path IS the path seen by the bridge.) Hence: no `sandbox_home` in the socket path.
  defp build_fleet_mcp_entry(spec, pod_dir, sandbox_home, pod_id, socket_path) do
    # HOST: where the spawner actually WRITES the bridge (the real pod_dir on disk).
    host_bridge = Path.join([pod_dir, ".lcars", "fleet_mcp_bridge.py"])

    # IN-NAMESPACE: what claude EXECUTES in the sandbox (pod_dir remapped → /home/.pod under bwrap).
    ns_bridge = Path.join([sandbox_home, ".lcars", "fleet_mcp_bridge.py"])
    ns_log = Path.join([sandbox_home, ".lcars", "fleet_mcp_bridge.log"])

    with :ok <- copy_bridge_into_pod(spec["bridge_source"], host_bridge) do
      args =
        (spec["args"] || [])
        |> Enum.map(fn arg ->
          arg
          |> String.replace("{{BRIDGE}}", ns_bridge)
          |> String.replace("{{BRIDGE_LOG}}", ns_log)
        end)

      pod_env = %{
        "LCARS_POD_ID" => pod_id,
        # Host path of the per-pod socket, set as-is (host == namespace, cf. the note above).
        "LCARS_FLEET_MCP_SOCKET" => socket_path
      }

      entry =
        spec
        |> Map.drop(["bridge_source"])
        |> Map.put("args", args)
        |> Map.put("alwaysLoad", true)
        |> Map.update("env", pod_env, &Map.merge(&1, pod_env))

      {:ok, entry}
    end
  end

  # nil = spec with no bridge to project (stub/legacy: the spec then carries a
  # `command`/`args` already self-contained, no placeholder to resolve).
  defp copy_bridge_into_pod(nil, _dest), do: :ok

  defp copy_bridge_into_pod(source, dest) when is_binary(source) do
    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _bytes} <- File.copy(source, dest),
         :ok <- File.chmod(dest, 0o755) do
      :ok
    else
      {:error, reason} -> {:error, {:mcp_bridge_provision_failed, source, reason}}
    end
  end
end
