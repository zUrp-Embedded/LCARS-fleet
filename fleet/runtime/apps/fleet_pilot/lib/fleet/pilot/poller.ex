defmodule Fleet.Pilot.Poller do
  @moduledoc """
  Réacteur du rail forge-state-machine (**mode STAGE uniquement**) : scan périodique du `repo`
  configuré, délégation des issues + PR ouvertes au spawn des rôles via `StageDispatcher`.

  ## Rôle

  La forge EST la machine à états ; ce poller en est le réacteur. À chaque tick, pour le `repo`
  surveillé, il liste les **issues** + **PR** ouvertes et délègue :

    * **issue assignée** (assignee=humain owner), non verrouillée, sans PR ouverte → spawn le rôle
      **producteur** (`StageDispatcher.dispatch_issue` ; rôle = `:producer_role`, défaut engineer).
    * **PR** avec reviewer demandé → spawn le **juge** ; PR `REQUEST_CHANGES` sans reviewer → re-spawn
      le **producteur** pour le rework (`StageDispatcher.dispatch_review`).
    * verrou `lcars-in-flight` → skip (un pod travaille déjà la brique). **Bail repo-sérialisé** :
      au plus un pipeline actif par repo (feature-branches séquentielles → merge FF garanti).

  ## Robustesse (port v1.5 `LcarsFleetPoller`, conservé)

    * **Jitter ±10%** sur l'interval — anti thundering-herd (N daemons qui redémarrent ensemble).
    * **Backoff exponentiel** sur erreurs API (capé à 5 min) — la forge down n'inonde pas les logs.
    * **Safety-net `try/rescue`** sur `do_poll/1` — un bug du path dispatch ne crash pas le poller.
    * **Telemetry** `[:fleet_pilot, :poller, :poll]` (duration_ms, dispatched, skipped, errors).

  ## Configuration init

    * `:repo` — `"owner/name"`, obligatoire.
    * `:interval_ms` — défaut `30_000` (30s).
    * `:forge_opts` — keyword ForgeClient (base_url, token, req_options).
    * `:stage_dispatch?` — historiquement le switch de mode ; aujourd'hui toujours `true` (seul mode).
    * seams test : `:forge_client`, `:loader`, `:carte_loader`, `:spawner`, `:clock` (injectés si non-nil).
    * `:start_tick?` — défaut `true` ; `false` = pas de 1er tick auto (tests drivent via `force_poll/1`).

  ## Historique — mode legacy RETIRÉ (②.3 / BL-050, 2026-06-16)

  L'ancien mode `do_poll` legacy (route-table `Routing.match_issue` → `Dispatcher.dispatch` →
  `Fleet.Pipeline.start_pipeline` = Executor RAM, via l'état de l'`AutoDispatcher`) a été **supprimé**
  avec le rail legacy (`auto_dispatcher`/`dispatcher`/`pipeline_invoker`). Seul le mode stage subsiste ;
  le moteur RAM tombe en aval.
  """

  use GenServer
  require Logger

  alias Fleet.Pilot.StageDispatcher

  # Verrou pipeline (source unique `Fleet.Pilot.Labels`) — lu par la réconciliation d'orphelins.
  @in_flight Fleet.Pilot.Labels.in_flight()

  @default_interval_ms 30_000
  @max_backoff_ms 300_000
  @jitter_ratio 0.1

  defstruct [
    :repo,
    :interval_ms,
    # #5.2 D1 — l'humain de CETTE fleet (OS user, `Human.current!()`). Scoping multi-user : on ne dispatche
    # QUE ses tickets (sinon le poller d'Alice spawne pour Bob). Seam test : opt `:human`.
    :my_human,
    :forge_client_override,
    stage_dispatch?: false,
    forge_opts: [],
    loader: nil,
    carte_loader: nil,
    spawner: nil,
    task_queue: nil,
    clock: nil,
    poll_count: 0,
    error_count: 0,
    err_streak: 0,
    last_error: nil,
    # F-033 : nb d'erreurs de DISPATCH (par item) du dernier tick. La liste forge
    # (`list_open_*`) peut réussir alors que des `dispatch_*` échouent — ces erreurs
    # incrémentent `err_streak` (backoff partiel via `next_delay`) au lieu d'être noyées.
    last_tally_errors: 0,
    # Réconciliation verrou (B) : refs `{:issue|:pr, n}` vues ORPHELINES (verrou `lcars-in-flight`
    # sans pod vivant) au tick précédent. Grace 2-tick (cf. PodWarden) → on ne réclame qu'au 2ᵉ
    # tick consécutif (évite de déverrouiller un pod fraîchement dispatché ou en cours de mort).
    orphan_lock_suspects: MapSet.new()
  ]

  @type t :: %__MODULE__{
          repo: String.t(),
          interval_ms: pos_integer(),
          forge_client_override: module() | nil,
          stage_dispatch?: boolean(),
          forge_opts: keyword(),
          loader: module() | nil,
          spawner: module() | nil,
          clock: (atom() -> integer()) | nil,
          poll_count: non_neg_integer(),
          error_count: non_neg_integer(),
          err_streak: non_neg_integer(),
          last_error: term() | nil,
          last_tally_errors: non_neg_integer()
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

  @doc "Stats runtime : poll_count, error_count, err_streak, last_error, last_tally_errors."
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
          # #5.2 D1 — scoping multi-user. Seam test : `:human` ; prod : `Human.current!()` (fail-loud — un
          # poller qui ne sait pas QUI il est ne peut pas scoper sûrement).
          my_human: Keyword.get(opts, :human) || Fleet.Credentials.Human.current!(),
          interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
          forge_client_override: Keyword.get(opts, :forge_client),
          stage_dispatch?: Keyword.get(opts, :stage_dispatch?, false),
          forge_opts: Keyword.get(opts, :forge_opts, []),
          loader: Keyword.get(opts, :loader),
          carte_loader: Keyword.get(opts, :carte_loader),
          spawner: Keyword.get(opts, :spawner),
          task_queue: Keyword.get(opts, :task_queue),
          clock: Keyword.get(opts, :clock)
        }

        if Keyword.get(opts, :start_tick?, true) do
          schedule(jitter(state.interval_ms))
        end

        Logger.info(
          "fleet_pilot Poller start repo=#{repo} mode=stage " <>
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
       last_error: state.last_error,
       last_tally_errors: state.last_tally_errors
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
  # Internals — GenServer poll orchestration
  # ============================================================

  # Mode STAGE uniquement (le legacy `do_poll`/Executor RAM a été retiré, ②.3). Le scan est dans
  # `stage_do_poll/1` ; ce wrapper conserve le point d'entrée unique (jitter/backoff/safety-net partagés).
  defp do_poll(state), do: stage_do_poll(state)

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
    # pipelines actifs. Corr.3 4-C : on liste AUSSI les PR ouvertes -> les JUGES sont dispatches
    # via les requested_reviewers de la PR (plus l'assignee issue). decide skip les in-flight.
    # #5.2 D1 — scoping multi-user FORGE-SIDE : MÊME filtre `assigned_by` pour issues ET PR (les deux passent
    # par /issues?type=… côté ForgeClient). Le poller ne voit QUE les items de SON humain → le scoping vit en
    # UN endroit (la liste), decide/dispatch_review ne re-vérifient plus l'ownership. Bail par-humain.
    scoped_opts = Keyword.put(state.forge_opts, :assigned_by, state.my_human)

    with {:ok, issues} <- forge.list_open_issues(state.repo, scoped_opts),
         {:ok, pulls} <- forge.list_open_pulls(state.repo, scoped_opts) do
      pr_issue_ids = pulls_issue_ids(pulls)

      # Réconciliation verrou (B) AVANT dispatch : un `lcars-in-flight` orphelin (pod mort sans avoir
      # complété → reapé, mais le label survit côté forge) bloquerait la brique pour TOUJOURS
      # (`dispatch_*` skip `:in_flight`). On le réclame (grace 2-tick) → le prochain tick re-dispatche.
      # Sans ça, un seul stall de pod wedge le pipe définitivement (live #8).
      new_suspects = reconcile_orphan_locks(issues, pulls, pr_issue_ids, state, forge)

      tally =
        merge_tally(
          stage_process_issues(issues, pr_issue_ids, state),
          stage_process_pulls(pulls, state)
        )

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

      # F-033 : la liste forge a réussi, mais des `dispatch_*` PAR ITEM ont pu échouer
      # (`tally.errors > 0` — ex. enqueue broker KO, spawn KO). Avant ce fix, `err_streak`
      # était remis à 0 inconditionnellement → ces erreurs ne ralentissaient JAMAIS le
      # poller (il martelait la forge au plein régime malgré l'échec). On réutilise le
      # mécanisme `err_streak`/`next_delay` (backoff partiel) : streak incrémenté tant que
      # des items échouent, reset à 0 seulement quand le tick est propre.
      {next_streak, next_last_error} =
        if tally.errors > 0 do
          {state.err_streak + 1, {:dispatch_errors, tally.errors}}
        else
          {0, nil}
        end

      {tally,
       %{
         state
         | poll_count: state.poll_count + 1,
           err_streak: next_streak,
           last_error: next_last_error,
           last_tally_errors: tally.errors,
           orphan_lock_suspects: new_suspects
       }}
    else
      {:error, reason} = err ->
        handle_poll_error(state, reason, started, err)
    end
  end

  # ── Réconciliation verrou orphelin (B, brique 2 du README) ────────────────────────────────────
  # Un verrou `lcars-in-flight` est ORPHELIN si la brique le porte mais qu'aucun pod vivant ne la
  # travaille. Cause : un pod mort (deadline `:result_timeout`, crash, restart BEAM) reapé par
  # le PodWarden — qui retire le PROCESS mais PAS le label forge. Symétrie cassée → le poller le
  # répare. Grace 2-tick (intersection avec les suspects du tick précédent) : on ne réclame qu'un
  # orphelin CONFIRMÉ, jamais un pod fraîchement dispatché (pas encore registré) ou en cours de mort.
  defp reconcile_orphan_locks(issues, pulls, pr_issue_ids, state, forge) do
    case live_owned_refs(state) do
      # Énumération des pods indisponible → fail-safe : on ne réclame RIEN (ne jamais déverrouiller
      # à l'aveugle), on garde les suspects en l'état.
      :error ->
        state.orphan_lock_suspects

      owned ->
        issue_orphans =
          for i <- issues,
              n = i["number"],
              locked?(i),
              # une issue avec PR ouverte est en phase JUGE (verrou côté PR) → pas un orphelin issue
              not MapSet.member?(pr_issue_ids, n),
              not MapSet.member?(owned, {:issue, n}),
              into: MapSet.new(),
              do: {:issue, n}

        pr_orphans =
          for p <- pulls,
              n = p["number"],
              locked?(p),
              not MapSet.member?(owned, {:pr, n}),
              into: MapSet.new(),
              do: {:pr, n}

        orphaned_now = MapSet.union(issue_orphans, pr_orphans)
        to_reclaim = MapSet.intersection(orphaned_now, state.orphan_lock_suspects)
        Enum.each(to_reclaim, fn {_type, n} -> reclaim_lock(forge, state, n) end)
        MapSet.difference(orphaned_now, to_reclaim)
    end
  end

  # Refs `{:issue|:pr, n}` qu'un pod travaille RÉELLEMENT, dérivées des pod_ids déterministes
  # (`issue-<n>-<role>-<ts>` / `pr-<n>-<role>-<ts>`). Filtre par **tâche active** (TaskQueue) : un
  # verrou n'est légitimement tenu QUE pendant qu'un pod a une tâche active dessus. Un pod VIVANT mais
  # IDLE (long-lived entre deux reworks, ex. l'engineer) ne « possède » PAS le verrou — sinon il
  # masquerait un juge MORT et la réconciliation ne réclamerait jamais (wedge live #8). `:error` si
  # l'énumération échoue (fail-safe : on ne réclame rien à l'aveugle).
  defp live_owned_refs(state) do
    spawner = state.spawner || Fleet.Spawner
    tq = state.task_queue || Fleet.TaskQueue

    spawner.list_pods()
    |> Enum.filter(&pod_has_active_task?(tq, &1[:pod_id]))
    |> Enum.flat_map(&parse_pod_ref(&1[:pod_id]))
    |> MapSet.new()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # Un pod a-t-il une tâche ACTIVE (assignée, non close) ? `{:ok, nil}` = idle. Tolérant (toute
  # anomalie → `false` : un pod dont on ne peut établir l'activité ne masque pas un orphelin).
  defp pod_has_active_task?(tq, pod_id) when is_binary(pod_id) do
    case tq.pod_status(pod_id) do
      {:ok, nil} -> false
      {:ok, _status} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp pod_has_active_task?(_tq, _), do: false

  defp parse_pod_ref(pod_id) when is_binary(pod_id) do
    case Regex.run(~r/^(issue|pr)-(\d+)-/, pod_id) do
      [_, "issue", n] -> [{:issue, String.to_integer(n)}]
      [_, "pr", n] -> [{:pr, String.to_integer(n)}]
      _ -> []
    end
  end

  defp parse_pod_ref(_), do: []

  defp locked?(item) do
    @in_flight in Enum.map(Map.get(item, "labels") || [], & &1["name"])
  end

  defp reclaim_lock(forge, state, number) do
    Logger.warning(
      "fleet_pilot Poller réconciliation : verrou #{@in_flight} ORPHELIN sur " <>
        "#{state.repo}##{number} (pod mort sans complétion) → réclamé (re-dispatch au prochain tick)"
    )

    forge.remove_label(state.repo, number, @in_flight, state.forge_opts)
  end

  # Issues portant une PR fleet ouverte (`lcars/issue-N-role`) = pipelines en phase JUGE :
  # le producteur a fini, la suite est dispatchee via les pulls -> le chemin issue les SKIP
  # (sinon le poller re-spawnerait le producteur, encore assigne).
  defp pulls_issue_ids(pulls) do
    pulls
    |> Enum.flat_map(fn pr ->
      case Fleet.Pilot.ForgeClient.parse_feature_branch(get_in(pr, ["head", "ref"]) || "") do
        {:ok, {n, _role}} -> [n]
        :error -> []
      end
    end)
    |> MapSet.new()
  end

  defp merge_tally(a, b) do
    %{
      dispatched: a.dispatched + b.dispatched,
      skipped: a.skipped + b.skipped,
      errors: a.errors + b.errors
    }
  end

  # Chemin PR-driven (Corr.3 4-C) : chaque PR ouverte avec une review demandee -> dispatch le juge.
  # Non garde par le bail (les juges d'un pipeline DEJA actif doivent avancer ; le bail ne borne
  # que l'ENTREE de nouveaux pipelines, cote issues).
  defp stage_process_pulls(pulls, state) do
    opts = stage_dispatch_opts(state)

    Enum.reduce(pulls, %{dispatched: 0, skipped: 0, errors: 0}, fn pr, acc ->
      case StageDispatcher.dispatch_review(pr, opts) do
        # ②.1d : `:ok` couvre `{:spawned, _, _}` (juge/rework spawné) ET `{:merged, _}` (PR scellée).
        {:ok, _} -> %{acc | dispatched: acc.dispatched + 1}
        {:skipped, _reason} -> %{acc | skipped: acc.skipped + 1}
        {:error, _reason} -> %{acc | errors: acc.errors + 1}
      end
    end)
  end

  defp stage_process_issues(issues, pr_issue_ids, state) do
    opts = stage_dispatch_opts(state)

    # #8 cohérence : le routing vit dans la ROUTE-COMMENT (state-machine, gravée par create_ticket) — plus
    # de routing par label, plus d'Entry. Le poller lit la route → dispatch (carte_role). Le bail
    # « 1 pipeline actif/repo » se lit AUSSI sur la route (robuste, append-only), PAS sur `state:*` (label
    # mutable). On classe chaque issue UNE fois (engaged? lit la route si besoin) :
    #   - ENGAGÉ (in-flight, ou route avancée au-delà du 1er stage = pipeline démarré) → tient le bail ;
    #     on dispatche son stage courant (continue le hop, ou skip si in-flight).
    #   - EN FILE (routé par create_ticket, route au 1er stage, pas encore dispatché) → démarre seulement
    #     si le bail est libre ; sinon attend (sérialisation → feature-branches séquentielles → FF merge).
    classified =
      Enum.map(issues, fn issue ->
        pr? = MapSet.member?(pr_issue_ids, Map.get(issue, "number"))
        {issue, pr?, not pr? and engaged?(issue, state)}
      end)

    lease_held0 = Enum.any?(classified, fn {_issue, _pr?, engaged} -> engaged end)

    {tally, _lease} =
      Enum.reduce(classified, {%{dispatched: 0, skipped: 0, errors: 0}, lease_held0}, fn
        {issue, pr?, engaged}, {acc, lease} ->
          payload = wrap_issue_as_payload(issue, state.repo)

          cond do
            # Corr.3 4-C : issue avec PR fleet ouverte → phase JUGE (dispatchée via les pulls). SKIP côté
            # issue (sinon re-spawn du producteur). La PR tient le bail.
            pr? ->
              {%{acc | skipped: acc.skipped + 1}, lease}

            # Pipeline ENGAGÉ → dispatche son stage courant ; il DÉTIENT le bail → lease inchangé.
            engaged ->
              stage_do_dispatch(payload, opts, acc, lease)

            # EN FILE, bail tenu par un autre pipeline → attend.
            lease ->
              {%{acc | skipped: acc.skipped + 1}, lease}

            # EN FILE, bail libre → DÉMARRE (prend le bail si effectivement dispatché).
            true ->
              start_pipeline(payload, opts, acc)
          end
      end)

    tally
  end

  defp stage_do_dispatch(payload, opts, acc, lease) do
    case StageDispatcher.dispatch_issue(payload, opts) do
      {:ok, {:spawned, _pod_id, _role}} ->
        {%{acc | dispatched: acc.dispatched + 1}, lease}

      {:skipped, _reason} ->
        {%{acc | skipped: acc.skipped + 1}, lease}

      {:error, _reason} ->
        {%{acc | errors: acc.errors + 1}, lease}
    end
  end

  # #8 — démarrage d'un pipeline EN FILE (bail libre) : dispatch ; si un pod est effectivement spawné, le
  # bail devient TENU (les autres tickets en file du même tick attendent → sérialisation 1 pipeline/repo).
  defp start_pipeline(payload, opts, acc) do
    {acc2, _} = stage_do_dispatch(payload, opts, acc, false)
    {acc2, acc2.dispatched > acc.dispatched}
  end

  # #8 — un pipeline est ENGAGÉ (tient le bail repo) si un pod est en vol (`in-flight` ; lecture liste,
  # 0 I/O) OU si sa ROUTE a avancé au-delà du 1er stage de la carte (= pipeline démarré, entre deux hops ;
  # lecture route-comment = state-machine robuste append-only, PAS `state:*` mutable). Un ticket
  # fraîchement routé par create_ticket (route = 1er stage, pas de pod) n'est PAS engagé → EN FILE. Pas de
  # route → A1 (pas engagé). La route n'est lue QUE si pas in-flight (fast-path, économise l'I/O).
  defp engaged?(issue, state) do
    labels = Enum.map(Map.get(issue, "labels") || [], & &1["name"])
    @in_flight in labels or pipeline_started?(issue, state)
  end

  defp pipeline_started?(issue, state) do
    forge = stage_forge_client(state)
    n = Map.get(issue, "number")

    case forge.get_route(state.repo, n, state.forge_opts) do
      {:ok, {carte, stage}} when is_binary(carte) and is_binary(stage) ->
        not at_first_stage?(carte, stage, state)

      _ ->
        false
    end
  end

  # Le stage courant est-il le 1er de la carte (= routé mais pas encore avancé = EN FILE) ? Toute anomalie
  # de carte → `true` (traité « non engagé » : le dispatch fail-loud surfacera, JAMAIS de wedge du bail
  # par une carte illisible).
  defp at_first_stage?(carte, stage, state) do
    loader = state.carte_loader || Fleet.Pipeline.Loader

    case Fleet.Pilot.CarteNav.first_stage(loader.load!(carte)) do
      {:ok, {first, _role}} -> stage == first
      _ -> true
    end
  rescue
    _ -> true
  end

  # Construit les opts de StageDispatcher.dispatch_issue. Les seams
  # (loader/spawner/task_queue/clock) ne sont injectés QUE s'ils sont set sur le
  # state — sinon StageDispatcher applique ses défauts réels (passer nil
  # écraserait le défaut).
  # F-028 : `:task_queue` était porté par le state (lu dans `live_owned_refs/1`)
  # mais JAMAIS transmis ici → StageDispatcher retombait sur `Fleet.TaskQueue`
  # global pour l'enqueue du mandat (seam de broker non honoré côté dispatch).
  defp stage_dispatch_opts(state) do
    [
      repo: state.repo,
      forge_client: stage_forge_client(state),
      forge_opts: state.forge_opts
    ]
    |> maybe_put_seam(:loader, state.loader)
    # #8 : `carte_role` (dispatch) charge la carte de la route → il lui faut le loader de CARTE (comme
    # fonction load!/1). Live : nil → défaut `Fleet.Pipeline.Loader.load!` (priv). Test : dérivé du module
    # stub. (Distinct de `:loader` = cap-profiles.)
    |> maybe_put_seam(:carte_loader, carte_loader_fun(state))
    |> maybe_put_seam(:spawner, state.spawner)
    |> maybe_put_seam(:task_queue, state.task_queue)
    |> maybe_put_seam(:clock, state.clock)
  end

  defp carte_loader_fun(%__MODULE__{carte_loader: nil}), do: nil
  defp carte_loader_fun(%__MODULE__{carte_loader: cl}), do: fn name -> cl.load!(name) end

  defp maybe_put_seam(opts, _key, nil), do: opts
  defp maybe_put_seam(opts, key, value), do: Keyword.put(opts, key, value)

  defp stage_forge_client(%__MODULE__{forge_client_override: nil}), do: Fleet.Pilot.ForgeClient
  defp stage_forge_client(%__MODULE__{forge_client_override: fc}), do: fc

  defp elapsed_ms(started_native) do
    System.convert_time_unit(
      System.monotonic_time() - started_native,
      :native,
      :millisecond
    )
  end
end
