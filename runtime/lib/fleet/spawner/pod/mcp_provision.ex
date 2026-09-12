defmodule Fleet.Spawner.Pod.McpProvision do
  @moduledoc """
  Provisions the pod’s MCP listener and, with a server spec, its bridge/config during projection.
  Without a spec, only StubBackend may skip config provisioning; real backends fail.
  The socket must exist before launch for bwrap to bind it. Provider resolution uses
  `McpSocketProvisioner`; the server spec comes from `:spawner_mcp_server_spec`.
  Pod supplies resolved paths/backend and handles projection failures. Termination
  uses the failure-tolerant release wrapper.
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

  # Copy the bridge into host pod_dir, but reference sandbox_home in the executable config:
  # the host pod directory is hidden by bwrap relocation. Host containment uses identical paths.
  # The socket is different: bwrap binds it at the same absolute path, with no remapping.
  # Its channel identifies the pod, not an ID supplied over the wire. alwaysLoad keeps tools
  # available on the first turn instead of deferring them behind ToolSearch.
  defp build_fleet_mcp_entry(spec, pod_dir, sandbox_home, _pod_id, socket_path) do
    host_bridge = Path.join([pod_dir, ".lcars", "fleet_mcp_bridge.py"])

    ns_bridge = Path.join([sandbox_home, ".lcars", "fleet_mcp_bridge.py"])
    ns_log = Path.join([sandbox_home, ".lcars", "fleet_mcp_bridge.log"])

    with :ok <- copy_bridge_into_pod(spec["bridge_source"], host_bridge) do
      # The placeholders occur inside bash -c (needed for log redirection). Quote paths so
      # spaces and shell metacharacters in a host pod’s home cannot become command syntax.
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

  # POSIX single-quoting: close, escape and reopen for embedded apostrophes.
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
