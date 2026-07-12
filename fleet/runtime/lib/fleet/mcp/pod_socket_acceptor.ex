defmodule Fleet.MCP.PodSocketAcceptor do
  @moduledoc """
  AF_UNIX socket acceptor for ONE pod: the pod's identity IS the channel.

  Each pod has ITS own socket, mounted into its sole sandbox. So every line
  received on THIS socket necessarily comes from THIS pod: the `pod_id` is the
  acceptor's immutable state (carried at startup, from the socket name), never
  read off the wire. There is nothing left to prove — no secret presented, no
  `pod_id` to compare: the channel discriminates. (The old HTTP loopback
  transport was shared by all pods; the `pod_id` there was guessable, hence the
  old capability. The per-pod socket closes that hole by construction.)

  One acceptor = one process = one socket: there is a genuine runtime reason (a
  socket is I/O state that persists across lines). It owns the listen socket,
  loops on `accept`, and hands each accepted connection to a dedicated Task
  (`Fleet.MCP.ConnectionTaskSupervisor`) — the loop re-`accept`s
  immediately; a slow handler blocks only ITS connection, never the following
  ones nor the other pods (each has its own acceptor). Supervised by
  `Fleet.MCP.PodSocketSupervisor` (DynamicSupervisor); named in the Registry
  `Fleet.MCP.PodSocketRegistry` (key = `pod_id`) for idempotent resolution.

  ## Protocol

  JSON-RPC newline-framed (`{:packet, :line}`), one message = one line. Only
  `method == "tools/call"` is served here: `initialize` / `tools/list` are
  answered locally by the stdio bridge (`bin/fleet_mcp_stdio_bridge.py`). The
  response frame reuses `Fleet.MCP.PodTools.handle_tool_call/3`:

    * `{:ok, content, _}`  → `result` = that `content` (already in MCP format);
    * `{:error, reason, _}` → `result` = `%{"content" => [text], "isError" => true}`
      (MCP convention: a tool error is a result with `isError`, not a protocol
      error — the pod reads it as tool text).
  """

  use GenServer

  require Logger

  alias Fleet.MCP.PodTools

  # AF_UNIX stream socket options, passive (we `recv` explicitly), one line per
  # message. `reuseaddr` is harmless here (a residual socket file is removed at
  # startup anyway — cf. `rm_stale/1`).
  # `buffer` MUST exceed the longest possible JSON-RPC line: with `packet: :line`,
  # a line longer than the buffer (inet default ~1460 B) is delivered TRUNCATED into
  # fragments, each fragment is invalid JSON, and the server then waited for a
  # complete line that never arrived -> silent hang, 30 s timeout on the bridge side,
  # tool payload > ~1.4 KB LOST (seen live 2026-07-04: arch brief + engineer/
  # reviewer summaries). 1 MiB covers every realistic payload; beyond that, handle_line answers -32700.
  @socket_opts [
    :binary,
    {:packet, :line},
    {:active, false},
    {:reuseaddr, true},
    {:buffer, 1_048_576}
  ]

  # Task.Supervisor (tree `Fleet.MCP.Supervisor`) where each accepted connection is served in its
  # own Task. Separates the SERVICE of a connection (potentially slow) from the accept LOOP.
  @conn_sup Fleet.MCP.ConnectionTaskSupervisor

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
    # F-C138 — role-GATED MCP tool names, threaded by the spawner (derived from the cap-profile
    # `allowedTools`). `tools/list` = base (universal) + these. `[]` = base-only (e.g. a judge role).
    tools = Keyword.get(opts, :tools, [])

    with :ok <- ensure_parent_dir(path),
         :ok <- rm_stale(path),
         {:ok, lsock} <- :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | @socket_opts]) do
      {:ok, %{pod_id: pod_id, socket_path: path, lsock: lsock, tools: tools},
       {:continue, :accept}}
    else
      {:error, reason} -> {:stop, {:socket_init_failed, reason}}
    end
  end

  # Recovery after FD exhaustion — re-enters the accept loop.
  @impl GenServer
  def handle_info(:retry_accept, state), do: {:noreply, state, {:continue, :accept}}

  @impl GenServer
  def handle_continue(:accept, %{lsock: lsock, pod_id: pod_id, tools: tools} = state) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        # CONCURRENT: each connection is served in its OWN Task, never inline here. Serving
        # inline (the old `serve(sock, pod_id)`) blocked the accept loop while ONE handler was pending
        # (e.g. a slow ~30 s forge call): we never came back to `accept`, so every following connection
        # from the pod stayed in the kernel backlog unserved → `readline` timeout on the bridge side
        # (the whole pod froze). One Task per connection → we re-`accept` right away; a slow handler
        # affects only its connection. `controlling_process` gives the socket to the worker (the acceptor can
        # re-accept / die without killing the in-flight connections); transfer failed (worker already dead) →
        # we close the socket rather than leak it.
        case Task.Supervisor.start_child(@conn_sup, fn -> serve(sock, pod_id, tools) end) do
          {:ok, pid} ->
            case :gen_tcp.controlling_process(sock, pid) do
              :ok -> :ok
              {:error, _} -> :gen_tcp.close(sock)
            end

          {:error, reason} ->
            # Notably :max_children (connection-pool saturation = a leaking bridge) —
            # VISIBLE: otherwise the pod just sees an inexplicable readline timeout.
            Logger.warning(
              "PodSocketAcceptor: pod=#{pod_id} connection REFUSED (#{inspect(reason)}) — leaking bridge?"
            )

            :gen_tcp.close(sock)
        end

        {:noreply, state, {:continue, :accept}}

      # Listen socket closed = we were stopped (release) → clean stop, not an error.
      {:error, :closed} ->
        {:stop, :normal, state}

      # FD exhaustion (emfile/enfile) = often TRANSIENT (a burst, a leak being reaped). Stopping
      # cascaded: acceptor → PodSocketSupervisor (3/5) → DEAD-EMPTY sup → all pods with no MCP
      # socket, nothing recreates them. Spaced retry bounded by the mailbox (a single :retry_accept
      # message in flight), VISIBLE; if the exhaustion persists, the pod will surface through its
      # own timeout (incident rail), not through a silent cascade.
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

  # Serves a connection line by line until the peer closes (the bridge does one
  # call = one line, then reads the response; it may chain several over the same
  # connection). On close / error, we hand control back to the accept loop.
  defp serve(sock, pod_id, tools) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, line} ->
        _ =
          case handle_line(line, pod_id, tools) do
            nil -> :ok
            frame -> :gen_tcp.send(sock, frame)
          end

        serve(sock, pod_id, tools)

      {:error, _reason} ->
        :gen_tcp.close(sock)
    end
  end

  # Decode the JSON-RPC line. Only `tools/call` is dispatched to PodTools. A
  # notification with no `id` is ignored (nothing to answer, JSON-RPC contract). An
  # INVALID JSON (truncated/broken line) -> -32700 response + warning: NEVER swallowed
  # silently — swallowing turned every invalid line into a 30 s timeout
  # indistinguable on the bridge side, zero BEAM trace (seen live 2026-07-04). Another `method`
  # with an `id` (anomaly: `initialize`/`tools/list` are served by the bridge) -> -32601.
  defp handle_line(line, pod_id, tools) do
    case Jason.decode(line) do
      {:ok, %{"method" => "tools/call", "id" => id, "params" => params}} ->
        encode(%{"jsonrpc" => "2.0", "id" => id, "result" => call_tool(params, pod_id)})

      # F-C138 — the pod socket NOW serves `tools/list` (it was answered by the stdio bridge from a
      # hard-coded catalogue that DRIFTED from the deftools — `import_project` was invisible to pods). Single
      # source: the schemas come from `PodTools.get_tools/0` (the `deftool` authority), filtered to this
      # pod's surface = base (universal) + the role-gated names threaded at spawn (derived from the
      # cap-profile `allowedTools`). Presence = authorization, per role. The bridge now forwards blindly.
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

  # `pod_id` comes from the acceptor's STATE (the channel), NEVER from `tool_args`: we
  # do not read an identity off the wire. The result format follows the MCP convention.
  # A slow tools/call must be VISIBLE on the server side: before 2026-07-04 a 30 s
  # hang left NO BEAM trace (the bridge logs on its side, but the server
  # was blind -> forensics impossible). Threshold deliberately high: we trace
  # the anomaly, not the noise.
  @slow_tool_warn_ms 5_000

  defp call_tool(params, pod_id) do
    tool = params["name"]
    tool_args = params["arguments"] || %{}

    {us, resp} =
      :timer.tc(fn -> safe_handle_tool_call(tool, tool_args, pod_id) end)

    ms = div(us, 1000)

    if ms > @slow_tool_warn_ms do
      Logger.warning("PodSocketAcceptor: pod=#{pod_id} tools/call #{tool} SLOW (#{ms} ms)")
    end

    case resp do
      {:ok, content, _state} ->
        content

      {:error, reason, _state} ->
        %{"content" => [%{"type" => "text", "text" => error_text(reason)}], "isError" => true}
    end
  end

  # `PodTools.handle_tool_call` is EXPECTED total (`{:ok}|{:error}`), but a bug/edge in a tool could RAISE
  # — an uncaught raise here KILLS the connection Task WITHOUT sending any response → the pod HANGS to its
  # own timeout (SOC-RES-001). Rescue into an `{:error, ...}` 3-tuple → the caller renders it as an MCP
  # `isError` result, so the pod ALWAYS gets an answer (MCP convention: a failure is a result, not a
  # dropped connection).
  defp safe_handle_tool_call(tool, tool_args, pod_id) do
    tool_handler().handle_tool_call(tool, tool_args, %{pod_id: pod_id})
  rescue
    e -> {:error, {:tool_crashed, tool, Exception.message(e)}, %{pod_id: pod_id}}
  catch
    kind, reason -> {:error, {:tool_crashed, tool, {kind, reason}}, %{pod_id: pod_id}}
  end

  # Tool dispatcher: the real `PodTools` in prod. Injectable (`:fleet_mcp, :tool_handler`) so a test can
  # supply a RAISING handler and prove the SOC-RES-001 rescue (a crashing tool → isError result, not a
  # dropped connection). Same seam pattern as `LaunchBackend`/`McpSocketProvisioner` elsewhere.
  defp tool_handler, do: Application.get_env(:fleet_mcp, :tool_handler, PodTools)

  # `PodTools.handle_tool_call` only returns error atoms/tuples (never a binary) → one clause
  # suffices; `inspect/1` renders any reason readable in the text field of the MCP error response.
  defp error_text(reason), do: inspect(reason)

  # F-C138 — the pod's tool SURFACE for `tools/list`: the deftool schemas (single source,
  # `PodTools.get_tools/0` = %{name => schema}) filtered to base (universal pod interface) + the role-gated
  # names threaded at spawn. `Map.take` silently drops a threaded name absent from the deftools (a stale
  # cap-profile entry can't invent a tool); the base is always present. We use `PodTools` directly (the
  # static catalogue authority), NOT the injectable `tool_handler` seam (which only swaps the CALL path).
  defp list_tools(threaded) do
    allowed = PodTools.base_tool_names() ++ threaded
    PodTools.get_tools() |> Map.take(allowed) |> Map.values() |> Enum.map(&to_mcp_wire/1)
  end

  # F1 — `get_tools/0` (ExMCP) rend sa forme INTERNE : `input_schema` (snake) + `display_name`/`meta`. Or CE
  # `tools/list` EST le wire MCP (le pont stdio le forwarde VERBATIM à claude), et le protocole MCP exige
  # `inputSchema` (camel). Un `input_schema` snake = claude ne parse pas le schéma → tool REJETÉ (« No such
  # tool available », claude re-`tools/list` en boucle sans jamais registrer). Avant F-C138 le pont portait un
  # catalogue camelCase à la main ; le passage au forward (single-source) a perdu la conversion. On projette
  # ICI, à la frontière socket=wire, vers les 3 champs MCP standard : central MCP-compliant, pont pur pass-through.
  defp to_mcp_wire(tool) do
    t = Map.new(tool, fn {k, v} -> {to_string(k), v} end)
    %{"name" => t["name"], "description" => t["description"], "inputSchema" => t["input_schema"]}
  end

  defp encode(map), do: Jason.encode!(map) <> "\n"

  defp ensure_parent_dir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, reason}}
    end
  end

  # A residual socket file (earlier crash) would make the bind fail
  # (`:eaddrinuse`). We remove it before re-listening; absent = nothing to do.
  defp rm_stale(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:rm_stale, reason}}
    end
  end
end
