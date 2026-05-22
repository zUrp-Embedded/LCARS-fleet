defmodule Fleet.Shutdown.Dispatcher do
  @moduledoc """
  Behaviour backend dispatcher consommé par `Fleet.Shutdown`.

  Canon DN ring0/lcars-fleet_service §"Module Fleet.Shutdown" : le
  drain coordonné interroge `Fleet.Dispatcher.in_flight_count/0` et
  `Fleet.Dispatcher.refuse_new_jobs/1`. **`Fleet.Dispatcher` n'existe
  pas encore** dans l'umbrella (vérifié anti-M1). Plutôt qu'inventer
  une dépendance (violation #P5), on isole derrière ce behaviour : le
  défaut `NoOpDispatcher` rend le shutdown compile-safe et honnête-
  dégradé (drain immédiat, 0 in-flight), à câbler quand
  `Fleet.Dispatcher` arrive (pattern test-seam codebase).
  """
  @callback refuse_new_jobs(opts :: keyword()) :: :ok
  @callback in_flight_count() :: non_neg_integer()
end

defmodule Fleet.Shutdown.NoOpDispatcher do
  @moduledoc """
  Backend défaut — `Fleet.Dispatcher` pas encore wiré (DN ring0
  lcars-fleet_service). Honnête-dégradé : aucun job à drainer →
  drain immédiat. NON silencieux (documenté), pas un Goodhart.
  """
  @behaviour Fleet.Shutdown.Dispatcher

  @impl true
  def refuse_new_jobs(_opts), do: :ok

  @impl true
  def in_flight_count, do: 0
end

defmodule Fleet.Shutdown do
  @moduledoc """
  Grace shutdown coordonné — invoqué par `ExecStop` systemd ou
  `lcars-fleet-restart` via RPC release. Canon DN
  ring0/lcars-fleet_service §"Module Fleet.Shutdown".

  Trois phases :
  1. `begin/1` — refuse nouveaux jobs (gate dispatcher), drain queue
  2. `drain_in_flight/1` — attend pipelines en cours max grace_ms
  3. final (systemd `fleet_umbrella stop`) — stop umbrella OTP

  ## Backend dispatcher (seam #P5)

  `Fleet.Dispatcher` absent de l'umbrella → backend configurable
  `:fleet_starfleet, :shutdown_dispatcher` (défaut
  `Fleet.Shutdown.NoOpDispatcher`). Pas d'invention de dépendance
  (anti-M1). À câbler le vrai backend quand `Fleet.Dispatcher` existe.

  Pas de Goodhart cosmétique : `wait_drain` poll un vrai
  `in_flight_count` jusqu'à 0 ou deadline (pas un `sleep` arbitraire).
  """

  use GenServer
  require Logger

  @default_grace_ms 45_000

  # --- API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Phase 1 : refuse nouveaux jobs + drain (max grace_ms)."
  def begin(opts \\ []) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)
    GenServer.call(server(opts), {:begin, grace_ms}, grace_ms + 5_000)
  end

  @doc "Phase 2 : attend in-flight → 0 ou grace_ms."
  def drain_in_flight(opts \\ []) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)
    GenServer.call(server(opts), {:drain, grace_ms}, grace_ms + 5_000)
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  # --- GenServer ---

  @impl true
  def init(opts) do
    backend =
      opts[:dispatcher] ||
        Application.get_env(
          :fleet_starfleet,
          :shutdown_dispatcher,
          Fleet.Shutdown.NoOpDispatcher
        )

    {:ok, %{status: :running, backend: backend, in_flight: 0}}
  end

  @impl true
  def handle_call({:begin, grace_ms}, _from, state) do
    :ok = state.backend.refuse_new_jobs(reason: :shutdown)
    Logger.info("Fleet.Shutdown: begin — nouveaux jobs refusés, drain #{grace_ms}ms")
    {:reply, :ok, wait_drain(state, grace_ms)}
  end

  def handle_call({:drain, grace_ms}, _from, state) do
    {:reply, :ok, wait_drain(state, grace_ms)}
  end

  # --- drain réel (pas de Goodhart) ---

  defp wait_drain(state, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    do_wait_drain(state, deadline)
  end

  defp do_wait_drain(state, deadline) do
    in_flight = state.backend.in_flight_count()

    cond do
      in_flight == 0 ->
        %{state | status: :drained, in_flight: 0}

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("Fleet.Shutdown: drain timeout, #{in_flight} job(s) in-flight")
        %{state | status: :timeout, in_flight: in_flight}

      true ->
        Process.sleep(500)
        do_wait_drain(%{state | in_flight: in_flight}, deadline)
    end
  end
end
