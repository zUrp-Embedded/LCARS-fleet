defmodule Fleet.Starfleet.Shutdown.Dispatcher do
  @moduledoc """
  Behaviour backend dispatcher consommé par `Fleet.Starfleet.Shutdown`.

  **Ce behaviour EST l'abstraction du drain** (décision user 2026-06-05, DN
  ring0 lcars-fleet_service amendée) : le croquis DN nommait un `Fleet.Dispatcher`
  global — il n'existe pas et ne doit PAS exister. Le seam `:shutdown_dispatcher`
  remplace ce contrat. Deux implémentations :

    * `NoOpDispatcher` — défaut test/fallback (0 in-flight, drain immédiat)
    * `AggregateDispatcher` — backend canon **prod** (câblé `runtime.exs`),
      agrège l'in-flight réel + active la quiescence
  """
  @callback refuse_new_jobs(opts :: keyword()) :: :ok
  @callback in_flight_count() :: non_neg_integer()
end

defmodule Fleet.Starfleet.Shutdown.NoOpDispatcher do
  @moduledoc """
  Backend **test/fallback** — drain immédiat, 0 in-flight. Honnête-dégradé :
  aucun job à drainer. Défaut en `:test` (hermétisme) et fallback de config si
  aucun backend réel câblé. NON silencieux (documenté), pas un Goodhart. Le
  backend prod est `AggregateDispatcher`.
  """
  @behaviour Fleet.Starfleet.Shutdown.Dispatcher

  @impl true
  def refuse_new_jobs(_opts), do: :ok

  @impl true
  def in_flight_count, do: 0
end

defmodule Fleet.Starfleet.Shutdown.AggregateDispatcher do
  @moduledoc """
  Backend **réel** du seam `:shutdown_dispatcher` — agrège l'in-flight et
  active la quiescence. Décision user (2026-06-05) : **pas** de god-module
  `Fleet.Dispatcher` ; le seam `:shutdown_dispatcher` EST l'abstraction (DN
  ring0 `lcars-fleet_service` amendée, retex montant).

  ## `refuse_new_jobs/1`

  Active `Fleet.Shutdown.Quiesce` → les points d'entrée top-level
  (`Fleet.Pipeline.start_pipeline/3`, REST `/api/admin/spawn`) refusent le
  travail neuf. Le travail interne d'un pipeline en vol n'est PAS gaté.

  ## `in_flight_count/0` — périmètre (décision user)

  **Tout pod vivant compte** (éphémère ET permanent) + pipelines en cours +
  mandats en file non-assignés :

    * `Fleet.Spawner.count_pods/0` — pods actifs (couvre aussi le travail
      assigné : un mandat assigné ⇒ son pod est vivant ⇒ compté ici)
    * `Fleet.Pipeline.count_running/0` — Executors vivants
    * `Fleet.TaskQueue.list_pending/0` — mandats en file **pas encore assignés**

  **Pas de double-comptage** : `list_pending` filtre `state == :pending` STRICT
  (cf. `task_queue/server.ex` `handle_call(:list_pending)`) — les mandats
  `:assigned`/`:in_progress` en sont exclus et sont représentés par leur pod
  vivant (compté dans `count_pods`). Ni double-comptage ni sous-comptage.

  ⚠ Conséquence assumée : des pods permanents (Type 1/3 « forever » :
  gatekeeper, archivist…) gardent `in_flight_count > 0` en permanence ⇒ sur un
  `begin/1` (full stop) le drain consomme toute la fenêtre de grâce puis
  procède (l'arrêt umbrella termine les pods de toute façon). C'est le
  comportement choisi : donner à chaque arrêt le budget de grâce complet.

  ## Layering

  `fleet_starfleet` dépend de `fleet_spawner` (`count_pods` en appel direct).
  Il NE dépend PAS de `fleet_pipeline`/`fleet_task_queue` (pas d'inversion) →
  leurs comptes sont lus par dispatch dynamique guardé (résilient si absents).
  """
  @behaviour Fleet.Starfleet.Shutdown.Dispatcher

  @impl true
  def refuse_new_jobs(_opts), do: Fleet.Shutdown.Quiesce.refuse!()

  @impl true
  def in_flight_count do
    spawner_pods() + pipeline_running() + tasks_pending()
  end

  defp spawner_pods do
    Fleet.Spawner.count_pods()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp pipeline_running do
    case dyn(Fleet.Pipeline, :count_running, []) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp tasks_pending do
    case dyn(Fleet.TaskQueue, :list_pending, []) do
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  # Dispatch dynamique guardé vers des apps non prises en dépendance
  # compile-time (pas d'inversion de layering) — cf. moduledoc.
  defp dyn(mod, fun, args) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end
end

defmodule Fleet.Starfleet.Shutdown do
  @moduledoc """
  Grace shutdown coordonné. Le déclencheur historique (`ExecStop` systemd /
  `lcars-fleet-restart`) est retiré (systemd parti 2026-06-16) — à recâbler sur
  `fleet_v2 stop` (backlog graceful-shutdown). La logique de drain reste valide.

  Trois phases :
  1. `begin/1` — refuse nouveaux jobs (gate dispatcher), drain queue
  2. `drain_in_flight/1` — attend pipelines en cours max grace_ms
  3. final (systemd `fleet_umbrella stop`) — stop umbrella OTP

  ## Backend dispatcher (seam `:shutdown_dispatcher`)

  Backend configurable `:fleet_starfleet, :shutdown_dispatcher` (défaut
  `NoOpDispatcher` test/fallback ; prod = `AggregateDispatcher` câblé
  `runtime.exs`). Le seam EST l'abstraction du drain (décision user 2026-06-05,
  pas de god-module `Fleet.Dispatcher` — DN ring0 amendée).

  Pas de Goodhart cosmétique : `wait_drain` poll un vrai `in_flight_count`
  jusqu'à 0 ou deadline (pas un `sleep` arbitraire).

  ## Blocage synchrone REQUIS (pas un anti-pattern à refactorer)

  `begin/1`/`drain_in_flight/1` bloquent dans le `handle_call` jusqu'à fin du
  drain : c'est la sémantique exigée. Le caller (`ExecStop` → `Fleet.Starfleet.Shutdown.begin`
  puis `fleet_umbrella stop`) DOIT savoir que le drain est terminé avant de
  stopper l'umbrella. Un reply async (`handle_continue`/`Task`) ferait stopper
  l'umbrella PENDANT le drain → garantie cassée. Pendant un shutdown il n'y a
  pas d'appel concurrent légitime vers ce GenServer ; le blocage est borné par
  `grace_ms` (+ SIGKILL systemd `TimeoutStopSec` en dernier recours).
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
          Fleet.Starfleet.Shutdown.NoOpDispatcher
        )

    {:ok, %{status: :running, backend: backend, in_flight: 0}}
  end

  @impl true
  def handle_call({:begin, grace_ms}, _from, state) do
    :ok = state.backend.refuse_new_jobs(reason: :shutdown)
    Logger.info("Fleet.Starfleet.Shutdown: begin — nouveaux jobs refusés, drain #{grace_ms}ms")
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
        Logger.warning("Fleet.Starfleet.Shutdown: drain timeout, #{in_flight} job(s) in-flight")
        %{state | status: :timeout, in_flight: in_flight}

      true ->
        Process.sleep(500)
        do_wait_drain(%{state | in_flight: in_flight}, deadline)
    end
  end
end
