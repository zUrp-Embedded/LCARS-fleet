defmodule Fleet.MCP.PodSocketAcceptor do
  @moduledoc """
  Per-pod AF_UNIX acceptor with startup-owned pod identity, never supplied by wire arguments.
  Identity relies on controlled socket access and sandbox mounts; no peer credential check
  distinguishes processes sharing the owner UID. Parent directory mode is checked as 0700
  before listening, then the socket is chmod 0600.

  Owns one listening socket and hands connections to supervised Tasks, allowing slow calls
  on one connection without serializing all connections. Per-pod and shared pool limits
  bound accepted workers; the idle deadline applies between frames, not during tool execution.

  Newline-framed JSON-RPC serves tools/list and tools/call; the stdio bridge handles initialize.
  Calls check base/threaded tool names, then the available input schema, then the handler's
  own role/subject gates. Schemas are sourced from PodTools for both listing and validation.

  Handler success returns its MCP content; handled errors become result.content with isError,
  not protocol errors. Malformed params or schema-resolution failures outside dispatch's
  rescue can still terminate a connection.
  """

  use GenServer

  require Logger

  alias Fleet.MCP.PodTools

  # Line buffer must contain a complete JSON-RPC frame; fragmented lines are invalid JSON.
  @socket_opts [
    :binary,
    {:packet, :line},
    {:active, false},
    {:reuseaddr, true},
    {:buffer, 1_048_576}
  ]

  # Compile-time limits: runtime put_env does not change these attributes. The idle timeout
  # releases mute connections; the per-pod cap below reserves room in the shared Task pool.
  @idle_timeout_ms Application.compile_env(:lcars_fleet, :mcp_socket_idle_timeout_ms, 300_000)

  @conn_sup Fleet.MCP.ConnectionTaskSupervisor

  @max_conns_per_pod Application.compile_env(:lcars_fleet, :mcp_max_conns_per_pod, 8)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    pod_id = Keyword.fetch!(opts, :pod_id)
    GenServer.start_link(__MODULE__, opts, name: via(pod_id))
  end

  defp via(pod_id), do: {:via, Registry, {Fleet.MCP.PodSocketRegistry, pod_id}}

  @impl GenServer
  def init(opts) do
    pod_id = Keyword.fetch!(opts, :pod_id)
    path = Keyword.fetch!(opts, :socket_path)

    tools = Keyword.get(opts, :tools, [])

    with :ok <- ensure_parent_dir(path),
         :ok <- rm_stale(path),
         {:ok, lsock} <- :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | @socket_opts]),
         :ok <- restrict(path, lsock) do
      {:ok, %{pod_id: pod_id, socket_path: path, lsock: lsock, tools: tools, conns: %{}},
       {:continue, :accept}}
    else
      {:error, reason} -> {:stop, {:socket_init_failed, reason}}
    end
  end

  # Require socket chmod before readiness; on failure close the listener and attempt removal.
  # The private parent directory must already cover the listen-to-chmod interval.
  defp restrict(path, lsock) do
    case File.chmod(path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = :gen_tcp.close(lsock)
        _ = File.rm(path)
        {:error, {:chmod_failed, path, reason}}
    end
  end

  @impl GenServer
  def handle_info(:retry_accept, state), do: {:noreply, state, {:continue, :accept}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | conns: Map.delete(state.conns, ref)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_continue(:accept, %{lsock: lsock, pod_id: pod_id} = state) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        # Blocking continue loop drains pending DOWNs before enforcing live capacity.
        state = reap_down(state)

        if live_conns(state) >= @max_conns_per_pod do
          Logger.warning(
            "PodSocketAcceptor: pod=#{pod_id} connection REFUSED — #{@max_conns_per_pod} " <>
              "concurrent connections already served for this pod (leaking bridge?); the " <>
              "fleet-wide Task pool is NOT consumed by this pod's excess"
          )

          :gen_tcp.close(sock)
          {:noreply, state, {:continue, :accept}}
        else
          {:noreply, spawn_conn(sock, state), {:continue, :accept}}
        end

      {:error, :closed} ->
        {:stop, :normal, state}

      # FD exhaustion retries instead of cascading acceptor loss.
      {:error, reason} when reason in [:emfile, :enfile] ->
        Logger.error(
          "PodSocketAcceptor: pod=#{pod_id} accept #{inspect(reason)} (FD exhaustion) — retry in 1s"
        )

        Process.send_after(self(), :retry_accept, 1_000)
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:accept_error, reason}, state}
    end
  end

  defp live_conns(%{conns: conns}), do: map_size(conns)

  # Non-blocking drain of monitored connection exits only.
  defp reap_down(state) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
        reap_down(%{state | conns: Map.delete(state.conns, ref)})
    after
      0 -> state
    end
  end

  # The monitored worker waits for `:go`, so recv cannot race socket ownership transfer.
  defp spawn_conn(sock, %{pod_id: pod_id, tools: tools} = state) do
    case Task.Supervisor.start_child(@conn_sup, fn -> await_go_then_serve(sock, pod_id, tools) end) do
      {:ok, pid} ->
        case :gen_tcp.controlling_process(sock, pid) do
          :ok ->
            send(pid, :go)
            ref = Process.monitor(pid)
            %{state | conns: Map.put(state.conns, ref, pid)}

          {:error, _} ->
            :gen_tcp.close(sock)
            state
        end

      {:error, reason} ->
        # Task start failures are logged as saturation, though other supervisor errors can reach here.
        Logger.warning(
          "PodSocketAcceptor: pod=#{pod_id} connection REFUSED (#{inspect(reason)}) — " <>
            "fleet-wide connection pool saturated"
        )

        :gen_tcp.close(sock)
        state
    end
  end

  # Frees a parked Task if its acceptor dies before transferring ownership.
  @go_timeout_ms 5_000

  defp await_go_then_serve(sock, pod_id, tools) do
    receive do
      :go -> serve(sock, pod_id, tools)
    after
      @go_timeout_ms ->
        Logger.warning(
          "PodSocketAcceptor: pod=#{pod_id} connection worker never got :go (acceptor gone?) — slot released"
        )
    end
  end

  # The deadline applies between frames, not while a tool call is executing.
  defp serve(sock, pod_id, tools) do
    case :gen_tcp.recv(sock, 0, @idle_timeout_ms) do
      {:ok, line} ->
        _ =
          case handle_line(line, pod_id, tools) do
            nil -> :ok
            frame -> :gen_tcp.send(sock, frame)
          end

        serve(sock, pod_id, tools)

      {:error, :timeout} ->
        Logger.warning(
          "PodSocketAcceptor: pod=#{pod_id} connection idle > #{div(@idle_timeout_ms, 1000)}s " <>
            "— closed (mute connections must not hold the fleet-wide Task pool)"
        )

        :gen_tcp.close(sock)

      {:error, _reason} ->
        :gen_tcp.close(sock)
    end
  end

  # Invalid JSON gets -32700 instead of a silent bridge timeout; unknown methods with non-nil IDs
  # get -32601. Decoded unmatched values are ignored, not fully validated as JSON-RPC requests.
  defp handle_line(line, pod_id, tools) do
    # Mark connection activity on every line, even invalid JSON, before decoding. This is a
    # TaskQueue startup hint for kick pacing, not proof that a TUI or agent is ready.
    Fleet.TaskQueue.mark_connected(pod_id)

    case Jason.decode(line) do
      {:ok, %{"method" => "tools/call", "id" => id, "params" => params}} ->
        encode(%{"jsonrpc" => "2.0", "id" => id, "result" => call_tool(params, pod_id, tools)})

      # Serve schemas from PodTools. The same base/threaded names authorize calls;
      # handler role gates remain an additional check, after surface/schema validation.
      {:ok, %{"method" => "tools/list", "id" => id}} ->
        encode(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => list_tools(tools)}})

      {:ok, %{"method" => method, "id" => id}} when not is_nil(id) ->
        encode(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{
            "code" => -32_601,
            "message" => "method #{method} not served by the pod socket"
          }
        })

      {:ok, _notification_sans_id} ->
        nil

      {:error, _decode_error} ->
        Logger.warning(
          "PodSocketAcceptor: pod=#{pod_id} undecodable line (#{byte_size(line)} B) -> -32700"
        )

        encode(%{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32_700, "message" => "parse error (invalid JSON line)"}
        })
    end
  end

  # Slow-call trace uses channel-owned identity, never a wire argument.
  @slow_tool_warn_ms 5_000

  # Enforce this socket's MCP subset even if a client knows an off-list tool name.
  # This is distinct from the vendor CLI's interpretation of scope.allowedTools.
  defp call_tool(params, pod_id, threaded) do
    tool = params["name"]
    tool_args = params["arguments"] || %{}

    if authorized?(tool, threaded) do
      case validate_arguments(tool, tool_args) do
        :ok ->
          dispatch_tool(tool, tool_args, pod_id)

        {:error, violations} ->
          Logger.warning(
            "PodSocketAcceptor: pod=#{pod_id} tools/call #{tool} REFUSED — arguments do not " <>
              "match the tool's inputSchema (#{violations})"
          )

          mark_activity(pod_id)

          %{
            "content" => [
              %{"type" => "text", "text" => error_text({:invalid_arguments, tool, violations})}
            ],
            "isError" => true
          }
      end
    else
      Logger.warning(
        "PodSocketAcceptor: pod=#{pod_id} tools/call #{inspect(tool)} REFUSED — outside this " <>
          "pod's declared MCP surface (base + scope.allowedTools)"
      )

      # Refusals count as activity: the client acted even though dispatch did not occur.
      mark_activity(pod_id)

      %{
        "content" => [%{"type" => "text", "text" => error_text({:tool_not_in_profile, tool})}],
        "isError" => true
      }
    end
  end

  defp authorized?(tool, threaded) when is_binary(tool),
    do: tool in PodTools.base_tool_names() or tool in threaded

  defp authorized?(_tool, _threaded), do: false

  # Validate the advertised schema after surface admission and before dispatch.
  # Cache per tool via SchemaCache; no schema means no validation. Extra keys depend on the
  # schema, and required/type validation does not replace semantic guards in the handler.
  defp validate_arguments(tool, tool_args) do
    case PodTools.get_tools()[tool] do
      %{input_schema: schema} when is_map(schema) ->
        resolved =
          Fleet.SchemaCache.cached({__MODULE__, :input_schema, tool}, fn ->
            ExJsonSchema.Schema.resolve(schema)
          end)

        case ExJsonSchema.Validator.validate(resolved, tool_args) do
          :ok ->
            :ok

          {:error, errors} ->
            {:error,
             Enum.map_join(errors, " · ", fn
               {msg, path} -> "#{path} : #{msg}"
               other -> inspect(other)
             end)}
        end

      _ ->
        :ok
    end
  end

  defp dispatch_tool(tool, tool_args, pod_id) do
    {us, resp} =
      :timer.tc(fn -> safe_handle_tool_call(tool, tool_args, pod_id) end)

    ms = div(us, 1000)

    if ms > @slow_tool_warn_ms do
      Logger.warning("PodSocketAcceptor: pod=#{pod_id} tools/call #{tool} SLOW (#{ms} ms)")
    end

    mark_activity(pod_id)

    case resp do
      {:ok, content, _state} ->
        content

      {:error, reason, _state} ->
        %{"content" => [%{"type" => "text", "text" => error_text(reason)}], "isError" => true}
    end
  end

  # Persist completion/refusal time for Pod.Liveness, which cannot call MCP across the boundary.
  # Do not touch on dispatch entry: a stuck handler must not look recently completed.
  # Ignore File.touch errors because this hint must not turn an observed call into a failure.
  defp mark_activity(pod_id) do
    marker =
      pod_id
      |> Fleet.MCP.PodSocketSupervisor.socket_path()
      |> Fleet.Layout.pod_mcp_activity_marker()

    _ = File.touch(marker)
    :ok
  end

  # Read effect classification beside the tool definitions rather than maintaining a remote name list.
  # Mutation and unknown effects share concurrent retries; completed results are not cached.
  # Durable repeat safety remains the handler's responsibility.
  @single_flight_effects [:mutation, :unknown]

  # SOC-RES-001: tool crashes become MCP error results instead of dropped connections.
  defp safe_handle_tool_call(tool, tool_args, pod_id) do
    handle = fn -> tool_handler().handle_tool_call(tool, tool_args, %{pod_id: pod_id}) end

    if PodTools.tool_effect(tool) in @single_flight_effects do
      key = {pod_id, tool, :crypto.hash(:sha256, :erlang.term_to_binary(tool_args))}
      Fleet.MCP.Idempotency.run(key, handle, succeeded?: &match?({:ok, _, _}, &1))
    else
      handle.()
    end
  rescue
    e -> {:error, {:tool_crashed, tool, Exception.message(e)}, %{pod_id: pod_id}}
  catch
    kind, reason -> {:error, {:tool_crashed, tool, {kind, reason}}, %{pod_id: pod_id}}
  end

  # Injectable seam exercises the SOC-RES-001 crash boundary.
  defp tool_handler, do: Application.get_env(:lcars_fleet, :mcp_tool_handler, PodTools)

  defp error_text(reason), do: inspect(reason)

  defp list_tools(threaded) do
    allowed = PodTools.base_tool_names() ++ threaded
    PodTools.get_tools() |> Map.take(allowed) |> Map.values() |> Enum.map(&to_mcp_wire/1)
  end

  # Project ExMCP's internal schema onto the MCP wire shape at the socket boundary.
  defp to_mcp_wire(tool) do
    t = Map.new(tool, fn {k, v} -> {to_string(k), v} end)
    %{"name" => t["name"], "description" => t["description"], "inputSchema" => t["input_schema"]}
  end

  defp encode(map), do: Jason.encode!(map) <> "\n"

  # A leaf mkdir error can hide the failing ancestor; report the first missing path and
  # whether its parent appears writable, rather than inferring the cause from errno alone.
  # Set and verify parent 0700 before listen: socket chmod comes after creation, too late
  # to prevent a different UID connecting during a permissive-umask interval.
  # These path-based checks are not atomic against concurrent replacement.
  defp ensure_parent_dir(path) do
    dir = Path.dirname(path)

    with :ok <- mkdir_private(dir),
         :ok <- close_dir(dir) do
      verify_private(dir)
    end
  end

  defp mkdir_private(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, reason, blame(dir)}}
    end
  end

  # A chmod error refuses startup; its errno alone does not establish directory ownership.
  defp close_dir(dir) do
    case File.chmod(dir, 0o700) do
      :ok -> :ok
      {:error, reason} -> {:error, {:chmod_dir, reason, blame(dir)}}
    end
  end

  # Read back permission bits after chmod; this does not verify owner or resolve races.
  defp verify_private(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{mode: mode}} ->
        case Bitwise.band(mode, 0o777) do
          0o700 -> :ok
          other -> {:error, {:dir_not_private, other, blame(dir)}}
        end

      {:error, reason} ->
        {:error, {:stat_dir, reason, blame(dir)}}
    end
  end

  defp blame(dir) do
    parts = Path.split(dir)

    missing =
      1..length(parts)
      |> Enum.map(&(parts |> Enum.take(&1) |> Path.join()))
      |> Enum.find(&(not File.exists?(&1)))

    case missing do
      # Existing paths can still fail mutation; report the target when none is missing.
      nil ->
        %{dir: dir, first_missing: nil, under: dir, under_writable?: writable?(dir)}

      m ->
        %{
          dir: dir,
          first_missing: m,
          under: Path.dirname(m),
          under_writable?: writable?(Path.dirname(m))
        }
    end
  end

  defp writable?(dir) do
    match?({:ok, %File.Stat{access: access}} when access in [:write, :read_write], File.stat(dir))
  end

  defp rm_stale(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:rm_stale, reason}}
    end
  end
end
