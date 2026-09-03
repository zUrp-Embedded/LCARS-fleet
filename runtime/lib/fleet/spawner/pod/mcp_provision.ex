defmodule Fleet.Spawner.Pod.McpProvision do
  @moduledoc """
  The pod↔fleet MCP CHANNEL, end to end — island extracted from `Fleet.Spawner.Pod`.

  The `fleet` MCP server is the SOLE pod↔fleet comm channel (never scraping). This module
  carries the WHOLE channel:

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

  The MCP server spec is read from config (`:lcars_fleet, :spawner_mcp_server_spec`); the resolved backend
  is passed by the Pod (single source `Fleet.Spawner.LaunchBackend.resolved/0`).
  """

  require Logger

  alias Fleet.Spawner.McpSocketProvisioner
  alias Fleet.Spawner.Pod.Fs

  defp mcp_socket_provisioner, do: McpSocketProvisioner.resolved()

  defp conforming_provisioner do
    mod = mcp_socket_provisioner()

    # function_exported?/3 does not load the module.
    _ = Code.ensure_loaded(mod)

    if function_exported?(mod, :ensure_pod_socket, 2) and
         function_exported?(mod, :release_pod_socket, 1) do
      {:ok, mod}
    else
      {:error, {:mcp_provisioner_misconfigured, mod}}
    end
  end

  @doc """
  Creates the pod listener before launch and returns its host socket path.

  The provisioner receives the role-gated MCP tool names served to this pod.
  """
  @spec ensure_pod_socket(String.t(), [String.t()]) :: {:ok, Path.t()} | {:error, term()}
  def ensure_pod_socket(pod_id, tools \\ []) when is_binary(pod_id) and is_list(tools) do
    with {:ok, mod} <- conforming_provisioner() do
      mod.ensure_pod_socket(pod_id, tools)
    end
  end

  @doc """
  Releases the pod listener and socket without propagating failures from termination.

  A state without a pod identifier is a no-op.
  """
  @spec release_pod_socket(map()) :: :ok
  def release_pod_socket(%{pod_id: pod_id}) when is_binary(pod_id) do
    case conforming_provisioner() do
      {:ok, mod} ->
        _ = mod.release_pod_socket(pod_id)

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

  defp mcp_server_spec, do: Application.get_env(:lcars_fleet, :spawner_mcp_server_spec)

  @doc "Returns whether the Fleet MCP server specification is configured."
  @spec server_spec_present?() :: boolean()
  def server_spec_present?, do: not is_nil(mcp_server_spec())

  @doc """
  Returns the pod process's `LCARS_POD_ID` and optional `LCARS_ROLE` introspection values.

  These values do not authenticate MCP requests; the receiving socket identifies the pod.
  """
  @spec mcp_channel_env(String.t(), String.t() | nil) :: %{String.t() => String.t()}
  def mcp_channel_env(pod_id, role) when is_binary(pod_id) do
    base = %{"LCARS_POD_ID" => pod_id}
    if is_binary(role) and role != "", do: Map.put(base, "LCARS_ROLE", role), else: base
  end

  @doc """
  Writes `.mcp-fleet.json` and projects the configured stdio bridge into the pod.

  The stub backend accepts an absent server spec. A real backend returns
  `{:error, {:mcp_server_spec_required, backend}}`; filesystem failures are returned unchanged.
  """
  @spec maybe_provision_mcp_config(Path.t(), Path.t(), String.t(), Path.t(), module()) ::
          :ok | {:error, term()}
  def maybe_provision_mcp_config(pod_dir, sandbox_home, pod_id, socket_path, backend) do
    case {mcp_server_spec(), backend} do
      {nil, Fleet.Spawner.LaunchBackend.StubBackend} ->
        :ok

      {nil, backend} ->
        {:error, {:mcp_server_spec_required, backend}}

      {spec, _backend} when is_map(spec) ->
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
  # bwrap projects a CLOSED WORLD for the pod — it mounts only
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
  # Injects `LCARS_FLEET_MCP_SOCKET` into the MCP server's env (the bridge reads it to know ON WHICH
  # socket to talk to the central; the central correlates `get_work_item` to the pod FROM that per-pod
  # socket — identity IS the channel, cf. `Fleet.MCP.PodSocketAcceptor`) and forces `alwaysLoad:true`
  # (otherwise the MCP tools are deferred behind ToolSearch, absent from the turn-1 prompt). NB: no
  # `LCARS_POD_ID` here — the bridge does not read it, and the pod's identity is never presented on
  # the wire (a forged one would be ignored; the socket is the sole authority).
  #
  # ⚠ Host vs namespace for the SOCKET: unlike the bridge (host_bridge for the copy, ns_bridge for
  # the argv), the `socket_path` is set AS-IS. The bwrap bind will mount the socket at the SAME absolute path
  # (`--bind X X`) → host == namespace → NO remap. (Host pods, containment none: no namespace at
  # all, the host path IS the path seen by the bridge.) Hence: no `sandbox_home` in the socket path.
  defp build_fleet_mcp_entry(spec, pod_dir, sandbox_home, _pod_id, socket_path) do
    # HOST: where the spawner actually WRITES the bridge (the real pod_dir on disk).
    host_bridge = Path.join([pod_dir, ".lcars", "fleet_mcp_bridge.py"])

    # IN-NAMESPACE: what claude EXECUTES in the sandbox (pod_dir remapped → /home/.pod under bwrap).
    ns_bridge = Path.join([sandbox_home, ".lcars", "fleet_mcp_bridge.py"])
    ns_log = Path.join([sandbox_home, ".lcars", "fleet_mcp_bridge.log"])

    with :ok <- copy_bridge_into_pod(spec["bridge_source"], host_bridge) do
      # SHELL-QUOTED, because the substitution lands inside a `bash -c` string. The spec's command
      # needs a shell for its `2>>` redirect, so the path cannot simply become an argv element —
      # which leaves quoting as the way to make it inert. Under bwrap `sandbox_home` is the literal
      # `/home/.pod` and nothing can go wrong; a HOST pod puts the real pod_dir here, derived from
      # the human's home, and a single space in it breaks the command while `;` or `$( )` would run
      # what they contain, in the pod's context. Quoting costs nothing on the safe path.
      args =
        (spec["args"] || [])
        |> Enum.map(fn arg ->
          arg
          |> String.replace("{{BRIDGE}}", sh_quote(ns_bridge))
          |> String.replace("{{BRIDGE_LOG}}", sh_quote(ns_log))
        end)

      pod_env = %{
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

  # POSIX single-quoting: everything between `'` is literal to the shell, and the only character
  # that cannot appear there is `'` itself — closed, escaped, reopened. No allow-list of "dangerous"
  # characters, which is the form that ages badly: one forgotten metacharacter and the guard is a
  # decoration.
  defp sh_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

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
