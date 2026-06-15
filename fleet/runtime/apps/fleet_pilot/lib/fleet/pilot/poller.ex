defmodule Fleet.Pilot.Poller do
  @moduledoc """
  Reconciliateur catch-up : scan périodique du `repo` configuré, pour
  chaque issue ouverte SANS label `lcars-dispatched`, tente le dispatch
  via `Fleet.Pilot.Dispatcher`.

  ## Pourquoi un poller en plus de l'AutoDispatcher

  L'AutoDispatcher consomme les webhook events Gitea live. Si le
  service est down quand un event survient, l'event est perdu
  (`Phoenix.PubSub` = pas de persistance, webhook = fire-and-forget).
  Le poller catch-up garantit "**l'issue est dispatchée si et seulement
  si elle porte le label `lcars-dispatched`**" — c'est la doctrine
  "label = source de vérité" (architecture-cible §"Idempotence
  inter-restart").

  ## Tungsten-proof (port v1.5 `LcarsFleetPoller`)

    * **Jitter ±10%** sur l'interval — évite thundering herd si N
      daemons redémarrent ensemble (cron, systemd cascade).
    * **Backoff exponentiel** sur erreurs API (capped à 5 min) — la
      forge down n'inonde pas les logs avec des retries rapides.
    * **Safety net `try/rescue`** sur `do_poll/1` — un bug imprévu
      dans le path dispatch ne crash pas le poller (perte du tracker
      backoff = re-flood au boot).
    * **Telemetry** `[:fleet_pilot, :poller, :poll]` (duration_ms,
      issues_count, dispatched_count, skipped_count, error_count).

  ## Deux modes de poll

    * **Legacy (route-table)** — défaut. `Routing.match_issue` (table
      `type:X → pipeline`) → `Dispatcher.dispatch` → Executor. Path
      historique dogfoodé, conservé tant que l'Executor n'est pas
      PROMOTE-retiré.
    * **Stage-dispatch (assignee-driven)** — `:stage_dispatch?` true.
      C'est le réacteur de la DN `orchestration/forge-state-machine.md` :
      pour chaque issue ouverte SANS `lcars-in-flight`, on appelle
      `StageDispatcher.dispatch_issue` (assignee = stage courant → spawn
      le rôle). **Découplé du legacy AutoDispatcher** : le mode stage ne
      lit PAS `ad_state` (l'Executor est SUPPRIMÉ dans ce modèle) ; il
      prend sa config forge via `:forge_opts` direct. Le même GenServer
      (jitter, backoff, telemetry, safety-net) sert les deux modes — on
      ne réinvente pas la tungsten-proofing.

  ## Configuration init

    * `:repo` — `"owner/name"`, obligatoire
    * `:interval_ms` — défaut `30_000` (30s, cohérent v1.5)
    * `:stage_dispatch?` — bool défaut `false`. `true` = mode
      assignee-driven (cf. ci-dessus).
    * `:forge_opts` — keyword passé au ForgeClient (base_url, token,
      req_options). Utilisé par le mode stage (le legacy le tire de
      `ad_state`).
    * `:auto_dispatcher` — name du process AutoDispatcher (défaut
      `Fleet.Pilot.AutoDispatcher`), utilisé par le mode LEGACY pour
      récupérer la config runtime (routes, forge_opts, modules injectés)
    * `:forge_client` — override module ForgeClient (légacy : défaut
      résolu via AutoDispatcher ; stage : défaut `ForgeClient`)
    * `:loader` / `:spawner` / `:clock` — seams du mode stage (défauts
      réels via `StageDispatcher`). Injectés seulement si non-nil.
    * `:subscribe?` — pas applicable (poller ne subscribe pas)
    * `:start_tick?` — bool défaut `true`. `false` = ne planifie pas
      le premier tick (utilisé par tests pour driver via
      `force_poll/1`)
  """

  use GenServer
  require Logger

  alias Fleet.Pilot.{Routing, Dispatcher, AutoDispatcher, StageDispatcher, Entry}

  @default_interval_ms 30_000
  @max_backoff_ms 300_000
  @jitter_ratio 0.1

  defstruct [
    :repo,
    :interval_ms,
    :auto_dispatcher,
    :forge_client_override,
    stage_dispatch?: false,
    forge_opts: [],
    routing: %{},
    loader: nil,
    carte_loader: nil,
    spawner: nil,
    clock: nil,
    poll_count: 0,
    error_count: 0,
    err_streak: 0,
    last_error: nil
  ]

  @type t :: %__MODULE__{
          repo: String.t(),
          interval_ms: pos_integer(),
          auto_dispatcher: GenServer.server(),
          forge_client_override: module() | nil,
          stage_dispatch?: boolean(),
          forge_opts: keyword(),
          loader: module() | nil,
          spawner: module() | nil,
          clock: (atom() -> integer()) | nil,
          poll_count: non_neg_integer(),
          error_count: non_neg_integer(),
          err_streak: non_neg_integer(),
          last_error: term() | nil
        }

  # ============================================================
  # Public API
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc "Force un poll immédiat (synchrone). Utilisé par tests + ops."
  @spec force_poll(GenServer.server()) :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }
  def force_poll(server \\ __MODULE__), do: GenServer.call(server, :force_poll, 30_000)

  @doc "Stats runtime : poll_count, error_count, err_streak, last_error."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} when is_binary(repo) and repo != "" ->
        state = %__MODULE__{
          repo: repo,
          interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
          auto_dispatcher: Keyword.get(opts, :auto_dispatcher, Fleet.Pilot.AutoDispatcher),
          forge_client_override: Keyword.get(opts, :forge_client),
          stage_dispatch?: Keyword.get(opts, :stage_dispatch?, false),
          forge_opts: Keyword.get(opts, :forge_opts, []),
          routing: Keyword.get(opts, :routing, %{}),
          loader: Keyword.get(opts, :loader),
          carte_loader: Keyword.get(opts, :carte_loader),
          spawner: Keyword.get(opts, :spawner),
          clock: Keyword.get(opts, :clock)
        }

        if Keyword.get(opts, :start_tick?, true) do
          schedule(jitter(state.interval_ms))
        end

        Logger.info(
          "fleet_pilot Poller start repo=#{repo} mode=#{if(state.stage_dispatch?, do: :stage, else: :legacy)} " <>
            "interval=#{state.interval_ms}ms jitter=±10%"
        )

        {:ok, state}

      _ ->
        {:stop, {:missing_required_opt, :repo}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {_result, new_state} = safe_poll(state)
    schedule(next_delay(new_state))
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:force_poll, _from, state) do
    {result, new_state} = safe_poll(state)
    {:reply, result, new_state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       poll_count: state.poll_count,
       error_count: state.error_count,
       err_streak: state.err_streak,
       last_error: state.last_error
     }, state}
  end

  # ============================================================
  # Internals — scheduling / safety
  # ============================================================

  defp schedule(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp next_delay(%__MODULE__{err_streak: 0, interval_ms: base}), do: jitter(base)

  defp next_delay(%__MODULE__{err_streak: streak, interval_ms: base}) do
    factor = :math.pow(2, min(streak, 10)) |> trunc()
    delay = min(base * factor, @max_backoff_ms)
    jitter(delay)
  end

  defp jitter(ms) do
    delta = trunc(ms * @jitter_ratio)
    offset = :rand.uniform(2 * delta + 1) - delta - 1
    max(ms + offset, 1_000)
  end

  # Retourne `{result, new_state}` — rescue-wrappé. Partagé par le tick (qui jette le
  # result) ET force_poll (qui le renvoie) : F184, force_poll ne bypasse plus le rescue.
  defp safe_poll(state) do
    do_poll(state)
  rescue
    exception ->
      Logger.error(
        "fleet_pilot Poller unexpected crash in do_poll: #{inspect(exception)} — state preserved"
      )

      {%{dispatched: 0, skipped: 0, errors: 1},
       %{
         state
         | error_count: state.error_count + 1,
           err_streak: state.err_streak + 1,
           last_error: inspect(exception)
       }}
  end

  # ============================================================
  # Poll core — pure function exposée pour tests
  # ============================================================

  @type tally :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc """
  Exécute un poll de bout en bout (list issues → match routes → dispatch).
  Pure côté logique : tous les effets passent par les modules injectés
  (`forge_client`, `dispatcher_config.forge_client`,
  `dispatcher_config.invoker`).

  Retourne `{:ok, tally}` ou `{:error, reason}`. Utilisé par le GenServer
  (via `do_poll/1`) et par les tests qui veulent éviter la friction
  GenServer + Process dictionary cross-process.
  """
  @spec poll_once(String.t(), Fleet.Pilot.Dispatcher.config(), [map()], module()) ::
          {:ok, tally()} | {:error, term()}
  def poll_once(repo, dispatcher_config, routes, forge_client)
      when is_binary(repo) and is_map(dispatcher_config) and is_list(routes) and
             is_atom(forge_client) do
    case forge_client.list_open_issues_without_label(
           repo,
           dispatcher_config.dispatch_label,
           dispatcher_config.forge_opts
         ) do
      {:ok, issues} ->
        {:ok, process_issues(issues, routes, dispatcher_config, repo)}

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Internals — GenServer poll orchestration
  # ============================================================

  defp do_poll(%__MODULE__{stage_dispatch?: true} = state), do: stage_do_poll(state)

  defp do_poll(state) do
    started = System.monotonic_time()

    with {:ok, ad_state} <- fetch_auto_dispatcher_state(state),
         dispatcher_config = build_dispatcher_config(ad_state, state),
         forge_client = forge_client(state, ad_state),
         {:ok, tally} <- poll_once(state.repo, dispatcher_config, ad_state.routes, forge_client) do
      duration_ms = elapsed_ms(started)

      :telemetry.execute(
        [:fleet_pilot, :poller, :poll],
        %{duration_ms: duration_ms},
        Map.merge(tally, %{
          status: :ok,
          repo: state.repo
        })
      )

      Logger.info(
        "fleet_pilot Poller tick repo=#{state.repo} " <>
          "dispatched=#{tally.dispatched} skipped=#{tally.skipped} errors=#{tally.errors} " <>
          "duration_ms=#{duration_ms}"
      )

      {tally, %{state | poll_count: state.poll_count + 1, err_streak: 0, last_error: nil}}
    else
      {:error, reason} = err ->
        handle_poll_error(state, reason, started, err)
    end
  end

  defp handle_poll_error(state, reason, started, _err) do
    new_streak = state.err_streak + 1

    Logger.warning(
      "fleet_pilot Poller error repo=#{state.repo} reason=#{inspect(reason)} streak=#{new_streak}"
    )

    :telemetry.execute(
      [:fleet_pilot, :poller, :poll],
      %{duration_ms: elapsed_ms(started)},
      %{
        status: :error,
        repo: state.repo,
        error: inspect(reason),
        err_streak: new_streak
      }
    )

    {%{dispatched: 0, skipped: 0, errors: 1},
     %{
       state
       | error_count: state.error_count + 1,
         err_streak: new_streak,
         last_error: inspect(reason)
     }}
  end

  defp process_issues(issues, routes, dispatcher_config, repo) do
    Enum.reduce(issues, %{dispatched: 0, skipped: 0, errors: 0}, fn issue, acc ->
      # Routing.match_issue attend un payload Gitea avec clé "issue" wrappée.
      # Le list API renvoie l'issue directement → on wrappe pour réutiliser
      # le même extract_fields.
      payload = wrap_issue_as_payload(issue, repo)

      case Routing.match_issue(payload, routes) do
        :no_match ->
          %{acc | skipped: acc.skipped + 1}

        {:match, pipeline_name} ->
          issue_number = Map.get(issue, "number")

          case Dispatcher.dispatch(
                 dispatcher_config,
                 pipeline_name,
                 repo,
                 issue_number,
                 payload
               ) do
            {:dispatched, _} -> %{acc | dispatched: acc.dispatched + 1}
            {:skipped, _} -> %{acc | skipped: acc.skipped + 1}
            {:error, _} -> %{acc | errors: acc.errors + 1}
          end
      end
    end)
  end

  defp wrap_issue_as_payload(issue, repo) do
    %{
      "issue" => issue,
      "repository" => %{"full_name" => repo}
    }
  end

  # ============================================================
  # Mode STAGE — réacteur assignee-driven (DN forge-state-machine §3/§6)
  # Découplé du legacy AutoDispatcher : pas de routes, pas d'Executor.
  # ============================================================

  defp stage_do_poll(state) do
    started = System.monotonic_time()
    forge = stage_forge_client(state)

    # Bail repo-serialise : on liste TOUS les ouverts (in-flight inclus) pour compter les
    # pipelines actifs. decide skip les in-flight (lcars-in-flight) ; le bail bloque les entrees.
    case forge.list_open_issues(state.repo, state.forge_opts) do
      {:ok, issues} ->
        tally = stage_process_issues(issues, state)
        duration_ms = elapsed_ms(started)

        :telemetry.execute(
          [:fleet_pilot, :poller, :poll],
          %{duration_ms: duration_ms},
          Map.merge(tally, %{status: :ok, mode: :stage, repo: state.repo})
        )

        Logger.info(
          "fleet_pilot Poller tick mode=stage repo=#{state.repo} " <>
            "dispatched=#{tally.dispatched} skipped=#{tally.skipped} errors=#{tally.errors} " <>
            "duration_ms=#{duration_ms}"
        )

        {tally, %{state | poll_count: state.poll_count + 1, err_streak: 0, last_error: nil}}

      {:error, reason} = err ->
        handle_poll_error(state, reason, started, err)
    end
  end

  defp stage_process_issues(issues, state) do
    opts = stage_dispatch_opts(state)
    entry_opts = stage_entry_opts(state)

    # Bail repo-serialise (incrément 3) : au plus 1 pipeline actif par repo. Un ticket deja
    # engage (assigne a un role, in-flight ou entre deux hops) tient le bail -> aucun ticket
    # NEUF n'entre tant qu'il n'est pas fini (merge -> close). Les feature-branches sont donc
    # creees sequentiellement (chacune descend du main a jour) -> merge FF garanti. Le dispatch
    # des hops du ticket en cours n'est PAS bloque (seule l'entree d'un neuf l'est). Parallele-
    # disjoint (1 pipeline/repo distinct) = optimisation differee.
    lease_held0 = Enum.any?(issues, &repo_lease_held?/1)

    {tally, _lease} =
      Enum.reduce(issues, {%{dispatched: 0, skipped: 0, errors: 0}, lease_held0}, fn issue,
                                                                                     {acc, lease} ->
        payload = wrap_issue_as_payload(issue, state.repo)

        case StageDispatcher.dispatch_issue(payload, opts) do
          {:ok, {:spawned, _pod_id, _role}} ->
            {%{acc | dispatched: acc.dispatched + 1}, lease}

          # Pas d'assignee : peut-être un ticket NEUF à ENTRER dans une carte (type:→carte, A2.1).
          # Entry est idempotent (déjà routé → skip). L'entrée n'est permise QUE si le bail repo
          # est libre (sinon le neuf attend le prochain tick, apres la fin du pipeline en cours).
          {:skipped, :no_assignee} ->
            stage_try_enter(payload, entry_opts, acc, lease)

          {:skipped, _reason} ->
            {%{acc | skipped: acc.skipped + 1}, lease}

          {:error, _reason} ->
            {%{acc | errors: acc.errors + 1}, lease}
        end
      end)

    tally
  end

  # Entree d'un ticket neuf, gardee par le bail repo. Bail tenu -> skip (:repo_leased, le neuf
  # attend). Bail libre -> Entry ; une entree reussie PREND le bail (les neufs suivants du meme
  # tick attendent).
  defp stage_try_enter(_payload, _entry_opts, acc, true),
    do: {%{acc | skipped: acc.skipped + 1}, true}

  defp stage_try_enter(payload, entry_opts, acc, false) do
    case Entry.enter(payload, entry_opts) do
      {:ok, {:entered, _role}} -> {%{acc | dispatched: acc.dispatched + 1}, true}
      {:skip, _} -> {%{acc | skipped: acc.skipped + 1}, false}
      {:error, _} -> {%{acc | errors: acc.errors + 1}, false}
    end
  end

  # Un ticket "tient le bail repo" s'il est deja engage dans un pipeline = assigne a un role
  # (in-flight ou entre deux hops : les deux portent un assignee ; un ticket neuf type:X non).
  defp repo_lease_held?(issue) do
    (Map.get(issue, "assignees") || []) != []
  end

  defp stage_entry_opts(state) do
    [
      repo: state.repo,
      routing: state.routing,
      forge_client: stage_forge_client(state),
      forge_opts: state.forge_opts
    ]
    # `:carte_loader` (Loader de pipeline, load!/1) ≠ `:loader` de StageDispatcher (CapProfile,
    # load/1). Entry navigue la carte → il lui faut le loader de carte, pas celui des cap-profiles.
    |> maybe_put_seam(:loader, state.carte_loader)
  end

  # Construit les opts de StageDispatcher.dispatch_issue. Les seams
  # (loader/spawner/clock) ne sont injectés QUE s'ils sont set sur le
  # state — sinon StageDispatcher applique ses défauts réels (passer nil
  # écraserait le défaut).
  defp stage_dispatch_opts(state) do
    [
      repo: state.repo,
      forge_client: stage_forge_client(state),
      forge_opts: state.forge_opts
    ]
    |> maybe_put_seam(:loader, state.loader)
    |> maybe_put_seam(:spawner, state.spawner)
    |> maybe_put_seam(:clock, state.clock)
  end

  defp maybe_put_seam(opts, _key, nil), do: opts
  defp maybe_put_seam(opts, key, value), do: Keyword.put(opts, key, value)

  defp stage_forge_client(%__MODULE__{forge_client_override: nil}), do: Fleet.Pilot.ForgeClient
  defp stage_forge_client(%__MODULE__{forge_client_override: fc}), do: fc

  defp fetch_auto_dispatcher_state(state) do
    case GenServer.call(state.auto_dispatcher, :get_state, 5_000) do
      %AutoDispatcher{} = ad_state -> {:ok, ad_state}
      other -> {:error, {:unexpected_ad_state, other}}
    end
  rescue
    exception -> {:error, {:auto_dispatcher_unavailable, exception}}
  catch
    :exit, reason -> {:error, {:auto_dispatcher_exit, reason}}
  end

  defp build_dispatcher_config(ad_state, _state) do
    AutoDispatcher.dispatcher_config(ad_state)
  end

  defp forge_client(%__MODULE__{forge_client_override: nil}, %AutoDispatcher{forge_client: fc}),
    do: fc

  defp forge_client(%__MODULE__{forge_client_override: fc}, _ad_state), do: fc

  defp elapsed_ms(started_native) do
    System.convert_time_unit(
      System.monotonic_time() - started_native,
      :native,
      :millisecond
    )
  end
end
