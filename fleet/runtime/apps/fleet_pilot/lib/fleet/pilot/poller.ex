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

  L'ancien mode `do_poll` legacy (route-table → `Dispatcher.dispatch` → `Fleet.Pipeline.start_pipeline`
  = Executor RAM, via l'état de l'`AutoDispatcher`) a été **supprimé** avec le rail legacy
  (`auto_dispatcher`/`dispatcher`/`pipeline_invoker`). Le module `Routing` lui-même a été retiré en
  #5.2 D4 (code mort). Seul le mode stage subsiste ; le moteur RAM tombe en aval.
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
    # #5.2 MULTI-PROJET : plus de `:repo` obligatoire — le poller DÉCOUVRE ses projets par topic
    # (`fleet_topic(my_human)`, repos `lcars-fleet-<human>`). `:repo` reste accepté (tests/legacy/seam)
    # mais n'est plus la source (do_poll l'écrase par itération). `my_human` = la VRAIE source requise
    # (#5.2 D1 ; `Human.current!()` fail-loud — un poller qui ne sait pas QUI il est ne peut pas scoper).
    state = %__MODULE__{
      repo: Keyword.get(opts, :repo),
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
      "fleet_pilot Poller start mode=stage MULTI-PROJET topic=#{fleet_topic(state.my_human)} " <>
        "interval=#{state.interval_ms}ms jitter=±10%"
    )

    {:ok, state}
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
    exception -> poll_crash(state, exception, "crash")
  catch
    kind, reason -> poll_crash(state, {kind, reason}, "exit/throw")
  end

  # F-S1-8 : rescue ET catch :exit/:throw — un `GenServer.call` vers une dép morte (enqueue→TaskQueue,
  # spawn→Spawner) lève `:exit`, PAS `{:error}` ; sans le catch, la boucle crashait (≠ « state preserved »
  # annoncé). On dégrade gracieusement (err_streak + backoff, state conservé), comme `live_owned_refs` et le
  # skill elixir « catch :exit on GenServer.call ».
  defp poll_crash(state, detail, kind_label) do
    Logger.error(
      "fleet_pilot Poller unexpected #{kind_label} in do_poll: #{inspect(detail)} — state preserved"
    )

    {%{zero_tally() | errors: 1},
     %{
       state
       | error_count: state.error_count + 1,
         err_streak: state.err_streak + 1,
         last_error: inspect(detail)
     }}
  end

  # ============================================================
  # Internals — GenServer poll orchestration
  # ============================================================

  # Mode STAGE uniquement (le legacy `do_poll`/Executor RAM a été retiré, ②.3). Le scan est dans
  # `stage_do_poll/1` ; ce wrapper conserve le point d'entrée unique (jitter/backoff/safety-net partagés).
  # #5.2 MULTI-PROJET : découverte forge-driven. Le poller scanne TOUS les projets de SON humain (repos
  # taggés `lcars-fleet-<human>` par l'onboarding), pas un `:repo` hard-codé. Per-repo : la logique stage
  # INCHANGÉE (state.repo posé par itération). Découverte OK → forge up → err_streak reset ; le scoping
  # ticket `assigned_by=my_human` (déjà, #5.2 D1) reste le garde anti-vol même si un repo d'Alice fuyait.
  # Découverte KO → backoff (handle_poll_error). Le bail repo-sérialisé reste per-repo (concurrent across,
  # séquentiel within).
  #
  # Per-repo state : les erreurs de DISPATCH per-item vivent dans la TALLY (pas le streak — un repo qui
  # liste mal ne backoff PAS toute la fleet, la forge est up puisque la découverte a réussi). MAIS l'état
  # de RÉCONCILIATION (`orphan_lock_suspects`, grace 2-tick) DOIT persister cross-tick : sans le re-thread,
  # la grace ne s'accumule jamais → un verrou orphelin n'est JAMAIS réclamé (le pipe wedge). On l'agrège
  # (union sur tous les repos) dans le state rendu. `poll_count` +1/tick (observabilité).
  # MA-02 — les refs de verrou sont désormais REPO-QUALIFIÉES (`{repo, :issue|:pr, n}`, cf. `live_owned_refs`/
  # `reconcile_orphan_locks`/`parse_pod_ref`) : l'union cross-repo des suspects ne collisionne plus sur le seul
  # numéro → un pod vivant #N/repoB NE masque PLUS un orphelin #N/repoA, et la grace 2-tick ne se contamine
  # plus entre repos (plus de double-spawn). La clé porte l'identité.
  defp do_poll(state) do
    forge = stage_forge_client(state)

    case forge.search_repos_by_topic(fleet_topic(state.my_human), state.forge_opts) do
      {:ok, repos} ->
        base = %{state | err_streak: 0, poll_count: state.poll_count + 1, last_error: nil}

        {tally, suspects} =
          Enum.reduce(repos, {zero_tally(), MapSet.new()}, fn repo, {acc_tally, acc_suspects} ->
            {t, st} = stage_do_poll(%{base | repo: repo})
            {merge_tally(acc_tally, t), MapSet.union(acc_suspects, st.orphan_lock_suspects)}
          end)

        {tally, %{base | orphan_lock_suspects: suspects, last_tally_errors: tally.errors}}

      {:error, reason} ->
        handle_poll_error(state, {:discover_repos, reason}, System.monotonic_time(), nil)
    end
  end

  @doc """
  Topic forge per-humain des projets de la fleet : `lcars-fleet-<human-sanitisé>`. **Source UNIQUE**
  partagée par l'onboarding (qui TAGUE le repo neuf) et le poller (qui DÉCOUVRE). Sanitize Gitea-topic
  (lowercase, `[a-z0-9-]`). C'est l'axe d'isolation REPO (Alice ne découvre pas les projets de Bob) ;
  l'axe TICKET (`assigned_by`) est la ceinture.
  """
  @spec fleet_topic(String.t()) :: String.t()
  def fleet_topic(human) when is_binary(human) do
    h = human |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
    "lcars-fleet-#{h}"
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

    {%{zero_tally() | errors: 1},
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

      # F-S1-6 : opts de dispatch calculées UNE fois/tick (partagées issues + pulls), pas 2×.
      opts = stage_dispatch_opts(state)

      tally =
        merge_tally(
          stage_process_issues(issues, pr_issue_ids, state, opts),
          stage_process_pulls(pulls, opts)
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
        repo = state.repo

        # MA-02 — orphelins REPO-QUALIFIÉS (`{repo, :issue|:pr, n}`) : la clé de verrou porte le repo, donc
        # `owned` (refs repo-scopées des pods vivants de CE repo) et `orphan_lock_suspects` (cross-tick, tous
        # repos) ne collisionnent plus sur le seul numéro. Un orphelin #N/repoA n'est plus masqué par un pod
        # vivant #N/repoB, et la grace 2-tick ne se contamine plus entre repos.
        issue_orphans =
          for i <- issues,
              n = i["number"],
              locked?(i),
              # une issue avec PR ouverte est en phase JUGE (verrou côté PR) → pas un orphelin issue
              not MapSet.member?(pr_issue_ids, n),
              not MapSet.member?(owned, {repo, :issue, n}),
              into: MapSet.new(),
              do: {repo, :issue, n}

        pr_orphans =
          for p <- pulls,
              n = p["number"],
              locked?(p),
              not MapSet.member?(owned, {repo, :pr, n}),
              into: MapSet.new(),
              do: {repo, :pr, n}

        orphaned_now = MapSet.union(issue_orphans, pr_orphans)
        to_reclaim = MapSet.intersection(orphaned_now, state.orphan_lock_suspects)
        Enum.each(to_reclaim, fn {_repo, _type, n} -> reclaim_lock(forge, state, n) end)
        MapSet.difference(orphaned_now, to_reclaim)
    end
  end

  # Refs `{repo, :issue|:pr, n}` qu'un pod travaille RÉELLEMENT, dérivées des pod_ids déterministes STABLES
  # (`<repo-slug>-issue-<n>-<role>` / `<repo-slug>-pr-<n>-<role>` ; plus de suffixe `-<ts>` depuis BL-055).
  # Filtre par **tâche active** (TaskQueue) : un verrou n'est légitimement tenu QUE pendant qu'un pod a une
  # tâche active dessus. Un pod VIVANT mais IDLE (long-lived entre deux reworks, ex. l'engineer) ne « possède »
  # PAS le verrou — sinon il masquerait un juge MORT et la réconciliation ne réclamerait jamais (wedge live #8).
  # `:error` si l'énumération échoue (fail-safe : on ne réclame rien à l'aveugle).
  #
  # MA-02 — SCOPE REPO : on ne garde QUE les pods de `state.repo` (préfixe `PodId.scope_prefix/1`), et la ref
  # rendue PORTE le repo (`{repo, :issue|:pr, n}`). Sans ça, un pod vivant #N/repoB « possédait » la ref
  # `{:issue, N}` globale → il MASQUAIT l'orphelin #N/repoA (verrou jamais réclamé = wedge) ET la grace 2-tick
  # se contaminait cross-repo (double-spawn). La clé de verrou est désormais REPO-QUALIFIÉE = l'identité réelle.
  defp live_owned_refs(state) do
    spawner = state.spawner || Fleet.Spawner
    tq = state.task_queue || Fleet.TaskQueue
    repo = state.repo

    spawner.list_pods()
    |> Enum.filter(&pod_has_active_task?(tq, &1[:pod_id]))
    |> Enum.flat_map(&parse_pod_ref(&1[:pod_id], repo))
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

  # MA-02 / F-037 / #25 : les pod_id sont **repo-scopés** (`<repo-slug>-issue-<n>-<role>`, cf.
  # `Fleet.Pilot.PodId`). On ANCRE le parse sur le préfixe de scope du REPO COURANT (`PodId.scope_prefix/1`),
  # suivi immédiatement du marqueur de phase `issue|pr-<n>-`. Double effet :
  #   1. SCOPE — un pod d'un AUTRE repo ne matche pas (son slug diffère) → il ne « possède » pas une ref de
  #      `state.repo` → fin du masquage cross-repo (#N/repoB masquant l'orphelin #N/repoA).
  #   2. DÉSAMBIGUÏSATION — l'ancrage exige `<slug>-(issue|pr)-` : un slug `fleet-poc` n'avale pas le pod
  #      `fleet-poc-2-issue-…` (après `fleet-poc-` vient `2`, pas `issue|pr`) → pas de faux positif de préfixe.
  # La ref rendue PORTE le repo (`{repo, :issue|:pr, n}`) = la clé complète (l'identité réelle du verrou).
  # (`PodId` reste « jamais re-parsé » sur sa SÉMANTIQUE — on ne reconstruit pas (n, role), on ANCRE pour
  # corréler la phase+numéro à un repo connu.)
  defp parse_pod_ref(pod_id, repo) when is_binary(pod_id) and is_binary(repo) do
    prefix = Regex.escape(Fleet.Pilot.PodId.scope_prefix(repo))

    case Regex.run(~r/^#{prefix}(issue|pr)-(\d+)-/, pod_id) do
      [_, "issue", n] -> [{repo, :issue, String.to_integer(n)}]
      [_, "pr", n] -> [{repo, :pr, String.to_integer(n)}]
      _ -> []
    end
  end

  defp parse_pod_ref(_, _), do: []

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

  # Tally vierge (source unique — F-S1-5). Les chemins d'erreur utilisent `%{zero_tally() | errors: 1}`.
  defp zero_tally, do: %{dispatched: 0, skipped: 0, errors: 0}

  # Chemin PR-driven (Corr.3 4-C) : chaque PR ouverte avec une review demandee -> dispatch le juge.
  # Non garde par le bail (les juges d'un pipeline DEJA actif doivent avancer ; le bail ne borne
  # que l'ENTREE de nouveaux pipelines, cote issues).
  defp stage_process_pulls(pulls, opts) do
    Enum.reduce(pulls, zero_tally(), fn pr, acc ->
      case StageDispatcher.dispatch_review(pr, opts) do
        # ②.1d : `:ok` couvre `{:spawned, _, _}` (juge/rework spawné) ET `{:merged, _}` (PR scellée).
        {:ok, _} -> %{acc | dispatched: acc.dispatched + 1}
        {:skipped, _reason} -> %{acc | skipped: acc.skipped + 1}
        {:error, _reason} -> %{acc | errors: acc.errors + 1}
      end
    end)
  end

  defp stage_process_issues(issues, pr_issue_ids, state, opts) do
    # #8 cohérence : le routing vit dans la ROUTE-COMMENT (state-machine, gravée à l'onboard) — plus de
    # routing par label. Le poller lit la route → dispatch (carte_role). Le bail « 1 pipeline actif/repo »
    # se lit AUSSI sur la route (robuste, append-only). On classe chaque issue UNE fois :
    #   - ENGAGÉ (in-flight, ou route avancée au-delà du 1er stage = pipeline démarré) → tient le bail ;
    #     on dispatche son stage courant (continue le hop, ou skip si in-flight).
    #   - EN FILE (routée au 1er stage, ou routeless à onboarder, pas encore dispatchée) → démarre seulement
    #     si le bail est libre ; sinon attend (sérialisation → feature-branches séquentielles → FF merge).
    # F-S1-1 : `classify_issue` lit la route (+ charge la carte) UNE fois et la THREAD au dispatch via
    # `prefetch` (mergé aux opts) → fin du double get_route / double load carte (la classif du bail et le
    # dispatch lisaient la MÊME donnée 2×).
    classified =
      Enum.map(issues, fn issue ->
        pr? = MapSet.member?(pr_issue_ids, Map.get(issue, "number"))
        {engaged, prefetch} = classify_issue(issue, pr?, state)
        {issue, pr?, engaged, prefetch}
      end)

    lease_held0 = Enum.any?(classified, fn {_issue, _pr?, engaged, _pf} -> engaged end)

    {tally, _lease} =
      Enum.reduce(classified, {zero_tally(), lease_held0}, fn
        {issue, pr?, engaged, prefetch}, {acc, lease} ->
          payload = wrap_issue_as_payload(issue, state.repo)
          item_opts = Keyword.merge(opts, prefetch)

          cond do
            # Corr.3 4-C : issue avec PR fleet ouverte → phase JUGE (dispatchée via les pulls). SKIP côté
            # issue (sinon re-spawn du producteur). La PR tient le bail.
            pr? ->
              {%{acc | skipped: acc.skipped + 1}, lease}

            # Pipeline ENGAGÉ → dispatche son stage courant ; il DÉTIENT le bail → lease inchangé.
            engaged ->
              stage_do_dispatch(payload, item_opts, acc, lease)

            # EN FILE, bail tenu par un autre pipeline → attend.
            lease ->
              {%{acc | skipped: acc.skipped + 1}, lease}

            # EN FILE, bail libre → DÉMARRE (prend le bail si effectivement dispatché).
            true ->
              start_pipeline(payload, item_opts, acc)
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

  # F-S1-1 — classifie une issue (bail) ET pré-résout ce que `dispatch_issue` relirait sinon. Renvoie
  # `{engaged?, prefetch_kw}` ; `prefetch_kw` (mergé aux opts de dispatch) porte `:prefetched_route` +
  # `:prefetched_carte` → lecture forge/disque UNE seule fois. ENGAGÉ = pod en vol (`in-flight`) OU route
  # avancée au-delà du 1er stage (pipeline démarré, entre deux hops). Fast-path : in-flight → pas de lecture
  # route (`decide` le skip de toute façon). Routeless (`:none`) → EN FILE, route nil threadée (onboard en
  # aval). Erreur HTTP get_route → EN FILE, RIEN threadé (le dispatch re-lit → fail-loud `:route_resolution`,
  # jamais de wedge du bail par une carte/route illisible).
  defp classify_issue(_issue, true = _pr?, _state), do: {false, []}

  defp classify_issue(issue, false = _pr?, state) do
    labels = Enum.map(Map.get(issue, "labels") || [], & &1["name"])

    if @in_flight in labels do
      {true, []}
    else
      forge = stage_forge_client(state)
      n = Map.get(issue, "number")

      case forge.get_route(state.repo, n, state.forge_opts) do
        {:ok, {carte, stage} = route} when is_binary(carte) and is_binary(stage) ->
          carte_map = load_carte_or_nil(carte, state)
          engaged = not is_nil(carte_map) and not first_stage?(carte_map, stage)
          {engaged, [prefetched_route: route, prefetched_carte: carte_map]}

        :none ->
          {false, [prefetched_route: nil]}

        _ ->
          {false, []}
      end
    end
  end

  # Charge la carte (seam `carte_loader` ou Loader réel) ; `nil` sur échec (le dispatch re-tentera → fail-loud).
  defp load_carte_or_nil(carte, state) do
    loader = state.carte_loader || Fleet.Pipeline.Loader
    loader.load!(carte)
  rescue
    _ -> nil
  end

  # Le stage est-il le 1er de la carte (= routé mais pas avancé = EN FILE) ? Anomalie carte → `true`
  # (traité « non engagé » : le dispatch fail-loud surfacera, jamais de wedge du bail par une carte illisible).
  defp first_stage?(carte_map, stage) do
    case Fleet.Pilot.CarteNav.first_stage(carte_map) do
      {:ok, {first, _role}} -> stage == first
      _ -> true
    end
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
