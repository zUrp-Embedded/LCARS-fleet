defmodule Fleet.Pilot.PermanentAgent do
  @moduledoc """
  GenServer Elixir client du sidecar Node `lcars-pilot-bridge` (P2.1).
  Owne le lifecycle du sidecar (Port-managed child Node process) + la
  connexion Unix socket pour dispatch task → result roundtrip.

  ## Archi A (cf. discussion design P2)

  Le sidecar utilise `@anthropic-ai/claude-agent-sdk` `query()` qui
  spawn son propre `claude --print` child par dispatch. **Sessions
  invisibles côté Desktop sidebar** — trade-off accepté pour livrer
  l'auto-dispatch LCARS-driven sans reverse-engineering du bridge
  protocol. Le `claude remote-control` parent (Phase 1) reste pour
  les user-tasks Desktop séparément.

  ## Lifecycle

    1. `init/1` ouvre Port sur `node <sidecar_path>/index.js`
    2. `handle_continue(:wait_socket)` poll FS jusqu'à apparition du
       fichier socket (timeout 5s)
    3. `handle_continue(:connect)` ouvre `:gen_tcp` Unix socket
    4. État `:ready` — accepte `dispatch/3` GenServer.call (timeout
       large : query() peut prendre 60s+)
    5. Sidecar Port exit → state.last_error set, GenServer crash →
       supervisor restart

  ## Facturation

  ⚠️ Indéterminé Anthropic post-15/06 (cf. issue GitHub claude-code#59823) :
  chaque dispatch peut tirer du quota Agent SDK bucket (payant) OU du
  pool subscription. À monitorer via `total_cost_usd` dans la result
  map (exposée via `stats/1`).
  """

  use GenServer
  require Logger

  @default_dispatch_timeout 120_000
  @socket_wait_timeout 5_000
  @socket_wait_interval 100

  defstruct [
    :role,
    :socket_path,
    :sp_file,
    :sidecar_path,
    :node_bin,
    :port,
    :socket,
    :status,
    dispatch_count: 0,
    error_count: 0,
    last_error: nil,
    last_cost_usd: 0.0
  ]

  @type t :: %__MODULE__{
          role: String.t(),
          socket_path: Path.t(),
          sp_file: Path.t() | nil,
          sidecar_path: Path.t(),
          node_bin: Path.t(),
          port: port() | nil,
          socket: :gen_tcp.socket() | nil,
          status: :booting | :ready | :failed,
          dispatch_count: non_neg_integer(),
          error_count: non_neg_integer(),
          last_error: term() | nil,
          last_cost_usd: float()
        }

  # ============================================================
  # Public API
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, via_name(Keyword.fetch!(opts, :role)))
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Envoie un prompt au sidecar, attend la réponse. Timeout 120s par
  défaut (override via `:timeout` opts).

  ## Returns

    * `{:ok, %{session_id, result, assistant_text, message_count}}` —
      dispatch réussi, result contient duration_ms, usage, cost
    * `{:error, reason}` — sidecar a renvoyé ok:false OU socket fail
  """
  @spec dispatch(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def dispatch(server, prompt, opts \\ []) when is_binary(prompt) do
    timeout = Keyword.get(opts, :timeout, @default_dispatch_timeout)
    request_opts = Keyword.get(opts, :sdk_options, %{})
    GenServer.call(server, {:dispatch, prompt, request_opts}, timeout)
  end

  @doc "Stats runtime : dispatch_count, error_count, last_error, last_cost_usd."
  @spec stats(GenServer.server()) :: map()
  def stats(server), do: GenServer.call(server, :stats)

  @doc "Probe sidecar via /stats op — health check."
  @spec ping(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def ping(server), do: GenServer.call(server, :ping, 10_000)

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(opts) do
    role = Keyword.fetch!(opts, :role)
    socket_path = Keyword.get(opts, :socket_path, default_socket_path(role))
    sp_file = Keyword.get(opts, :system_prompt_file)
    sidecar_path = Keyword.get(opts, :sidecar_path, default_sidecar_path())
    node_bin = Keyword.get(opts, :node_bin, find_node_bin())

    state = %__MODULE__{
      role: role,
      socket_path: socket_path,
      sp_file: sp_file,
      sidecar_path: sidecar_path,
      node_bin: node_bin,
      status: :booting
    }

    {:ok, state, {:continue, :start_sidecar}}
  end

  @impl GenServer
  def handle_continue(:start_sidecar, state) do
    # Cleanup stale socket file from previous run
    File.rm(state.socket_path)

    args = build_sidecar_args(state)

    port =
      Port.open(
        {:spawn_executable, state.node_bin},
        [:binary, :exit_status, {:args, [state.sidecar_path | args]}]
      )

    Logger.info(
      "fleet_pilot PermanentAgent #{state.role} sidecar started pid=#{inspect(port_info_pid(port))}"
    )

    {:noreply, %{state | port: port}, {:continue, {:wait_socket, 0}}}
  end

  def handle_continue({:wait_socket, elapsed}, state)
      when elapsed < @socket_wait_timeout do
    if File.exists?(state.socket_path) do
      {:noreply, state, {:continue, :connect}}
    else
      Process.sleep(@socket_wait_interval)
      {:noreply, state, {:continue, {:wait_socket, elapsed + @socket_wait_interval}}}
    end
  end

  def handle_continue({:wait_socket, _elapsed}, state) do
    {:stop, {:socket_wait_timeout, state.socket_path}, state}
  end

  def handle_continue(:connect, state) do
    case :gen_tcp.connect({:local, String.to_charlist(state.socket_path)}, 0, [
           :binary,
           :local,
           active: false,
           packet: :line
         ]) do
      {:ok, socket} ->
        Logger.info(
          "fleet_pilot PermanentAgent #{state.role} connected socket=#{state.socket_path}"
        )

        {:noreply, %{state | socket: socket, status: :ready}}

      {:error, reason} ->
        {:stop, {:socket_connect_failed, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:dispatch, prompt, sdk_opts}, _from, %{status: :ready} = state) do
    req = %{op: "dispatch", prompt: prompt, options: sdk_opts}

    case send_request(state.socket, req) do
      {:ok, %{"ok" => true} = resp} ->
        cost = get_in(resp, ["result", "total_cost_usd"]) || 0.0

        new_state = %{
          state
          | dispatch_count: state.dispatch_count + 1,
            last_cost_usd: cost
        }

        {:reply, {:ok, atomize_top(resp)}, new_state}

      {:ok, %{"ok" => false, "error" => error}} ->
        new_state = %{state | error_count: state.error_count + 1, last_error: error}
        {:reply, {:error, {:sidecar, error}}, new_state}

      {:error, reason} = err ->
        new_state = %{state | error_count: state.error_count + 1, last_error: reason}
        {:reply, err, new_state}
    end
  end

  def handle_call({:dispatch, _, _}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       role: state.role,
       status: state.status,
       socket_path: state.socket_path,
       dispatch_count: state.dispatch_count,
       error_count: state.error_count,
       last_error: state.last_error,
       last_cost_usd: state.last_cost_usd
     }, state}
  end

  def handle_call(:ping, _from, %{status: :ready} = state) do
    case send_request(state.socket, %{op: "stats"}) do
      {:ok, %{"ok" => true, "stats" => sidecar_stats}} ->
        {:reply, {:ok, sidecar_stats}, state}

      {:ok, other} ->
        {:reply, {:error, {:unexpected_response, other}}, state}

      {:error, reason} = err ->
        {:reply, err, %{state | last_error: reason}}
    end
  end

  def handle_call(:ping, _from, state),
    do: {:reply, {:error, {:not_ready, state.status}}, state}

  @impl GenServer
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error(
      "fleet_pilot PermanentAgent #{state.role} sidecar exited code=#{code} — supervisor will restart"
    )

    {:stop, {:sidecar_exited, code}, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_port(port) do
    # stderr/stdout du sidecar — log au niveau debug, pas critique
    Logger.debug("fleet_pilot PermanentAgent #{state.role} sidecar: #{data}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)

    if state.port && Port.info(state.port) do
      try do
        Port.close(state.port)
      rescue
        _ -> :ok
      end
    end

    File.rm(state.socket_path)
    :ok
  end

  # ============================================================
  # Internals
  # ============================================================

  defp build_sidecar_args(state) do
    base = ["--socket", state.socket_path, "--role", state.role]
    if state.sp_file, do: base ++ ["--system-prompt-file", state.sp_file], else: base
  end

  defp send_request(socket, req) do
    line = Jason.encode!(req) <> "\n"

    with :ok <- :gen_tcp.send(socket, line),
         {:ok, response_line} <- :gen_tcp.recv(socket, 0, :infinity),
         {:ok, parsed} <- Jason.decode(String.trim(response_line)) do
      {:ok, parsed}
    end
  end

  defp atomize_top(%{} = map) do
    Map.new(map, fn
      {"ok", v} -> {:ok, v}
      {"session_id", v} -> {:session_id, v}
      {"message_count", v} -> {:message_count, v}
      {"assistant_text", v} -> {:assistant_text, v}
      {"result", v} -> {:result, v}
      {k, v} -> {k, v}
    end)
  end

  defp via_name(role), do: {:via, Registry, {Fleet.Pilot.PermanentAgentRegistry, role}}

  defp default_socket_path(role) do
    Path.join(["/tmp", "lcars-pilot-#{role}.sock"])
  end

  defp default_sidecar_path do
    Application.app_dir(:fleet_pilot, ["priv", "sidecar", "lcars-pilot-bridge", "index.js"])
  end

  defp find_node_bin do
    System.find_executable("node") || raise "node binary not found in PATH"
  end

  defp port_info_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end
end
