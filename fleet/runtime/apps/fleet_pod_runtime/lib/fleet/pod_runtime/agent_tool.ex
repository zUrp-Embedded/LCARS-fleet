defmodule Fleet.PodRuntime.AgentTool do
  @moduledoc """
  GenServer fire-mode pour spawn agent-as-tool sub-pod (PoC-π2 PROVEN).

  Coordonne le lifecycle d'un sub-pod claude -p isolé via
  `Fleet.Spawner.spawn_pod/3` (chantier 6 PROMOTED) avec cap-profile
  `fire-mode-quick`. Cohérent doctrine `agent-as-tool` PROMOTED
  beyond_#2.

  ## Cap-profile fire-mode-quick (default contract)

      max_alive_sec : 60
      cost_cap_usd  : 0.20
      output_format : json-strict

  Valeurs exactes confirmées post-1ère implem runtime mesure (cap-profile
  schema deferred design note ch7).

  ## API

    * `spawn/2` — convenience function : démarre la GenServer, attend
      complétion sub-pod, retourne `{:ok, %{output, cost_usd, duration_ms}}`
      ou `{:error, term()}`.

  ## Backend swappable

  Le spawn de sub-pod est délégué à `SpawnerBackend` configurable
  pour tests (default délègue à `Fleet.Spawner.spawn_pod/3`). Permet
  isolation tests sans démarrer un pod réel.
  """

  use GenServer, restart: :temporary

  alias Fleet.PodRuntime.AgentTool

  defmodule SpawnerBackend do
    @moduledoc """
    Behaviour wrap autour de `Fleet.Spawner.spawn_pod/3` pour tests.
    """

    @callback spawn_pod(
                cap_profile :: term(),
                pod_id :: String.t(),
                opts :: keyword()
              ) :: {:ok, pid()} | {:error, term()}

    @callback await_result(pod_id :: String.t(), timeout :: non_neg_integer()) ::
                {:ok, %{output: map(), cost_usd: float(), duration_ms: non_neg_integer()}}
                | {:error, term()}
  end

  defmodule SpawnerBackend.Default do
    @moduledoc """
    Délègue à `Fleet.Spawner.spawn_pod/3` (chantier 6).
    `await_result/2` placeholder retourne `:not_wired_yet` — câblage
    réel attendu post-pod-1.18 + chantier 11 events router.
    """

    @behaviour AgentTool.SpawnerBackend

    @impl AgentTool.SpawnerBackend
    def spawn_pod(cap_profile, pod_id, opts),
      do: Fleet.Spawner.spawn_pod(cap_profile, pod_id, opts)

    @impl AgentTool.SpawnerBackend
    def await_result(_pod_id, _timeout), do: {:error, :not_wired_yet}
  end

  defstruct [:brief, :pod_id, :cap_profile, :timeout_ms, :backend, :started_at]

  @type result :: %{output: map(), cost_usd: float(), duration_ms: non_neg_integer()}

  @doc """
  Spawn synchrone d'un sub-pod fire-mode et attend son résultat.

  ## Inputs

    * `brief` — string brief du sub-pod
    * `opts` :
      * `:cap_profile` (obligatoire) — `%Fleet.CapProfile{}` `fire-mode-quick`
      * `:pod_id` (obligatoire) — string id sub-pod
      * `:timeout_ms` (default 60_000)
      * `:backend` (default `SpawnerBackend.Default`)

  Retourne `{:ok, %{output, cost_usd, duration_ms}}` ou `{:error, reason}`.
  """
  @spec spawn(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def spawn(brief, opts) when is_binary(brief) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    {:ok, pid} = GenServer.start_link(__MODULE__, [{:brief, brief} | opts])
    GenServer.call(pid, :await, timeout + 1_000)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      brief: Keyword.fetch!(opts, :brief),
      pod_id: Keyword.fetch!(opts, :pod_id),
      cap_profile: Keyword.fetch!(opts, :cap_profile),
      timeout_ms: Keyword.get(opts, :timeout_ms, 60_000),
      backend: Keyword.get(opts, :backend) || default_backend(),
      started_at: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:await, _from, %__MODULE__{} = state) do
    reply = run_fire_mode(state)
    {:stop, :normal, reply, state}
  end

  defp run_fire_mode(%__MODULE__{} = state) do
    with {:ok, _pid} <-
           state.backend.spawn_pod(state.cap_profile, state.pod_id, brief: state.brief),
         {:ok, %{} = result} <- state.backend.await_result(state.pod_id, state.timeout_ms) do
      duration_ms = System.monotonic_time(:millisecond) - state.started_at
      {:ok, Map.put(result, :duration_ms, duration_ms)}
    end
  end

  defp default_backend do
    Application.get_env(
      :fleet_pod_runtime,
      :agent_tool_backend,
      Fleet.PodRuntime.AgentTool.SpawnerBackend.Default
    )
  end
end
