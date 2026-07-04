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

  Active `Fleet.Shutdown.Quiesce` → le point d'entrée top-level REST
  `/api/admin/spawn` (`Fleet.API.Rest` lit `quiescing?`) refuse le travail neuf.
  (Le moteur RAM `Fleet.Workflow.start_pipeline/3`, autre point d'entrée gaté
  historiquement, est SUPPRIMÉ.) Le travail interne d'un step_run en vol n'est PAS gaté.

  ## `in_flight_count/0` — périmètre (décision user)

  **Tout pod vivant compte** (éphémère ET permanent) + work items en file
  non-assignés. Il n'y a PLUS de pipelines RAM à compter : le moteur
  `Fleet.Workflow.Executor` est supprimé (un pod vivant = un step_run en cours).

    * `Fleet.Spawner.count_pods/0` — pods actifs (couvre aussi le travail
      assigné : un work item assigné ⇒ son pod est vivant ⇒ compté ici)
    * `Fleet.TaskQueue.list_pending/0` — work items en file **pas encore assignés**

  **Pas de double-comptage** : `list_pending` filtre `state == :pending` STRICT
  (cf. `task_queue/server.ex` `handle_call(:list_pending)`) — les work items
  `:assigned`/`:in_progress` en sont exclus et sont représentés par leur pod
  vivant (compté dans `count_pods`). Ni double-comptage ni sous-comptage.

  ⚠ Conséquence assumée : des pods permanents (Type 1/3 « forever » :
  gatekeeper, archivist…) gardent `in_flight_count > 0` en permanence ⇒ sur un
  `begin/1` (full stop) le drain consomme toute la fenêtre de grâce puis
  procède (l'arrêt umbrella termine les pods de toute façon). C'est le
  comportement choisi : donner à chaque arrêt le budget de grâce complet.

  **Fail-CLOSED quand le comptage échoue** : si un composant (Spawner / broker
  task_queue) est PRÉSENT mais injoignable — typiquement un restart EN PLEIN
  quiesce — son comptage rend un sentinel > 0 (jamais `0`) → le drain ne conclut
  jamais « vide » sur une ignorance, il attend son timeout (le garde-fou).
  L'ancien `0` était fail-OPEN : sous-comptage ⇒ drain déclaré complet à tort ⇒
  arrêt PENDANT du travail en vol. Une app task_queue GENUINEMENT absente du
  build reste `0` (il n'y a réellement rien à drainer) — on distingue « absent »
  de « planté » via les applications réellement démarrées, pas le code path
  (en umbrella tous les modules sont chargeables, ça ne distinguerait rien).

  ## Layering

  `fleet_starfleet` dépend de `fleet_spawner` (`count_pods` en appel direct — le
  seam app-env `:spawner_mod` n'existe QUE pour injecter un stub en test, défaut
  = le vrai `Fleet.Spawner`). Il NE dépend PAS de `fleet_task_queue` (pas
  d'inversion) → `list_pending` est lu par `apply` (module en variable, aucune
  dépendance compile-time), résilient si l'app est absente.
  """
  @behaviour Fleet.Starfleet.Shutdown.Dispatcher

  require Logger

  # Sentinel « comptage in-flight indisponible ». La condition de fin de drain (`do_wait_drain`) ne
  # conclut « vide » que sur `in_flight == 0` → toute valeur > 0 EMPÊCHE de conclure et force le drain
  # à attendre son timeout (le garde-fou, jamais un blocage indéfini). 1 = minimal « pas vide ». On
  # rend cette valeur quand le comptage ÉCHOUE (composant injoignable) : fail-CLOSED (« je ne sais pas
  # ⇒ je ne déclare PAS le drain complet »), à l'opposé du fail-open `0` qui coupait pendant du travail.
  @count_unavailable 1

  # Module spawner — défaut le vrai `Fleet.Spawner` (appel direct, dép compile-time réelle). App-env
  # seam UNIQUEMENT pour injecter un stub en test (induire un count_pods qui lève/exit) ; la prod ne
  # pose jamais cette clé → comportement = appel direct `Fleet.Spawner.count_pods/0`.
  @spawner_default Fleet.Spawner

  @impl true
  def refuse_new_jobs(_opts), do: Fleet.Shutdown.Quiesce.refuse!()

  @impl true
  def in_flight_count do
    # `pipeline_running` RETIRÉ (②.3 / BL-050) : le moteur RAM (`Fleet.Workflow.Executor`) est supprimé,
    # il n'y a plus de pipelines en RAM à drainer. L'in-flight = les **pods vivants** (le travail réel
    # du rail forge : un pod = un step_run en cours) + les work items **en file** non encore pullés.
    spawner_pods() + tasks_pending()
  end

  # Pods vivants. fleet_spawner est une dép compile-time DURE (toujours présente en prod) : un
  # `count_pods` qui lève/exit = le Spawner est injoignable, ANORMAL — typiquement un restart EN PLEIN
  # quiesce. On ne masque PLUS en `0` (le `0` faisait sous-compter l'in-flight → drain déclaré complet
  # à tort → arrêt PENDANT du travail en vol, fail-open). À la place : Logger.error + sentinel « pas
  # vide » → le drain ne conclut pas, il attend son timeout (garde-fou).
  defp spawner_pods do
    spawner_mod().count_pods()
  rescue
    e ->
      Logger.error(
        "Fleet.Starfleet.Shutdown: comptage pods vivants indisponible (Spawner injoignable — restart " <>
          "en plein quiesce ?) — drain ne peut PAS conclure 0, on reste prudent : #{Exception.message(e)}"
      )

      @count_unavailable
  catch
    :exit, reason ->
      Logger.error(
        "Fleet.Starfleet.Shutdown: comptage pods vivants indisponible (Spawner exit #{inspect(reason)} " <>
          "— restart en plein quiesce ?) — drain ne peut PAS conclure 0, on reste prudent"
      )

      @count_unavailable
  end

  defp spawner_mod, do: Application.get_env(:fleet_starfleet, :spawner_mod, @spawner_default)

  # Mandats en file non-assignés. `fleet_starfleet` ne dépend PAS de `fleet_task_queue` (pas
  # d'inversion de layering) → appel par `apply` (module en variable : aucune référence d'appel remote
  # → aucune dép compile-time). Deux régimes à NE PAS confondre :
  #   * app task_queue ABSENTE de ce build/env (légitime : test isolé starfleet, déploiement sans le
  #     broker) → il n'y a réellement AUCUNE file à drainer → `0` HONNÊTE (pas un masque d'échec).
  #   * app PRÉSENTE mais l'appel lève/exit (broker en restart pendant le quiesce) → ANORMAL : on ne
  #     masque PAS en `0` (sous-comptage ⇒ drain conclurait « vide » à tort) → sentinel « pas vide ».
  # En umbrella tous les modules sont chargeables, donc « module chargé » ne distingue pas absent de
  # planté : on tranche sur l'app RÉELLEMENT démarrée (`started_applications`), pas sur le code path.
  defp tasks_pending do
    if task_queue_running?() do
      case safe_count_pending() do
        {:ok, n} ->
          n

        :error ->
          Logger.error(
            "Fleet.Starfleet.Shutdown: comptage work items en file indisponible (broker task_queue " <>
              "présent mais injoignable — restart en plein quiesce ?) — drain ne peut PAS conclure 0, prudent"
          )

          @count_unavailable
      end
    else
      0
    end
  end

  defp task_queue_running? do
    List.keymember?(Application.started_applications(), :fleet_task_queue, 0)
  end

  # Module en VARIABLE pour l'`apply` : pas d'appel remote `Fleet.TaskQueue.x()` littéral → aucune
  # dépendance compile-time vers fleet_task_queue (le layering interdit l'inversion).
  defp safe_count_pending do
    mod = Fleet.TaskQueue

    case apply(mod, :list_pending, []) do
      list when is_list(list) -> {:ok, length(list)}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
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

  # Défaut canon du backend dispatcher : NoOp (drain inerte) tant que le vrai
  # backend prod `AggregateDispatcher` n'est pas câblé (runtime.exs). Posé ICI une
  # seule fois — voir `configured_dispatcher/0`.
  @default_dispatcher Fleet.Starfleet.Shutdown.NoOpDispatcher

  # --- API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Backend dispatcher résolu depuis la config (`:fleet_starfleet, :shutdown_dispatcher`),
  défaut `NoOpDispatcher`. SOURCE UNIQUE du défaut : ce process le lit à l'`init` et la
  readiness (sonde anti-vert-creux) le lit aussi — aucun des deux ne re-déclare le défaut,
  donc pas de drift entre le drain réel et ce que la readiness croit câblé. (L'override de
  test `opts[:dispatcher]` reste géré localement par l'`init`, hors config.)
  """
  @spec configured_dispatcher() :: module()
  def configured_dispatcher do
    Application.get_env(:fleet_starfleet, :shutdown_dispatcher, @default_dispatcher)
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
    # `opts[:dispatcher]` = override de test injecté ; sinon le backend résolu depuis la
    # config via la source unique (défaut canon NoOp inclus).
    backend = opts[:dispatcher] || configured_dispatcher()

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
