defmodule Fleet.Pilot.Poller do
  @moduledoc """
  Réacteur du rail forge-state-machine (**mode STEP uniquement**) : scan périodique du `repo`
  configuré, délégation des issues + PR ouvertes au spawn des rôles via `StepDispatcher`.

  ## Rôle

  La forge EST la machine à états ; ce poller en est le réacteur. À chaque tick, pour le `repo`
  surveillé, il liste les **issues** + **PR** ouvertes et délègue :

    * **issue assignée** (assignee=humain owner), non verrouillée, sans PR ouverte → spawn le rôle
      **producteur** (`StepDispatcher.dispatch_issue` ; rôle = `:producer_role`, défaut engineer).
    * **PR** avec reviewer demandé → spawn le **juge** ; PR `REQUEST_CHANGES` sans reviewer → re-spawn
      le **producteur** pour le rework (`StepDispatcher.dispatch_review`).
    * verrou `lcars-in-flight` → skip (un pod travaille déjà la brique). **Bail repo-sérialisé** :
      au plus un workflow_run actif par repo (feature-branches séquentielles → merge FF garanti).

  ## Robustesse (port v1.5 `LcarsFleetPoller`, conservé)

    * **Jitter ±10%** sur l'interval — anti thundering-herd (N daemons qui redémarrent ensemble).
    * **Backoff exponentiel** sur erreurs API (capé à 5 min) — la forge down n'inonde pas les logs.
    * **Safety-net `try/rescue`** sur `do_poll/1` — un bug du path dispatch ne crash pas le poller.
    * **Telemetry** `[:fleet_pilot, :poller, :poll]` (duration_ms, dispatched, skipped, errors).

  ## Configuration init

    * `:repo` — `"owner/name"`, obligatoire.
    * `:interval_ms` — défaut `30_000` (30s).
    * `:forge_opts` — keyword ForgeClient (base_url, token, req_options).
    * `:step_dispatch?` — historiquement le switch de mode ; aujourd'hui toujours `true` (seul mode).
    * seams test : `:forge_client`, `:loader`, `:workflow_map_loader`, `:spawner` (injectés si non-nil).
    * `:start_tick?` — défaut `true` ; `false` = pas de 1er tick auto (tests drivent via `force_poll/1`).

  ## Historique — mode legacy RETIRÉ (2026-06-16)

  L'ancien mode `do_poll` legacy (route-table → `Dispatcher.dispatch` → `Fleet.Workflow.start_pipeline`
  = Executor RAM, via l'état de l'`AutoDispatcher`) a été **supprimé** avec le rail legacy
  (`auto_dispatcher`/`dispatcher`/`pipeline_invoker`). Le module `Routing` lui-même a été retiré
  comme code mort. Seul le mode step subsiste ; le moteur RAM tombe en aval.
  """

  use GenServer
  require Logger

  alias Fleet.Pilot.Opts
  alias Fleet.Pilot.Poller.Reconciliation
  alias Fleet.Pilot.StepDispatcher

  # Verrou workflow_run (source unique `Fleet.Pilot.Labels`) — fast-path `classify_issue` (in-flight →
  # ENGAGÉ sans lecture de route). La réconciliation d'orphelins re-dérive le SIEN de la même autorité
  # (`Reconciliation`), même source, pas un fork.
  @in_flight Fleet.Pilot.Labels.in_flight()

  # Verrou HUMAIN posé sur l'ISSUE à l'escalade (verdict gatekeeper escalate/halt/redirect, ou conflit non
  # résolu). Le poller calcule le SET des issues qui le portent (déjà listées au tick → zéro I/O) et le thread
  # aux pulls → `dispatch_review` skippe le juge d'une PR dont l'issue parente attend l'arch.
  @awaits_arch Fleet.Pilot.Labels.awaits_arch()

  @default_interval_ms 30_000
  @max_backoff_ms 300_000
  @jitter_ratio 0.1

  # G4 — cadence de RE-KICK de l'arch tant qu'au moins une issue attend (`lcars-awaits-arch`). Throttlé :
  # 1 wake tous les N ticks (à ~30s/tick, N=10 = ~5 min). Un wake peut coûter un TOUR claude → non throttlé,
  # ce serait un churn 30s (dépense non bornée, anti-Jupiter). Assez fréquent pour qu'un wake perdu ne bloque
  # pas une issue POUR TOUJOURS, assez rare pour ne pas marteler le sas humain.
  @awaits_rekick_every 10

  defstruct [
    :repo,
    :interval_ms,
    # L'humain de CETTE fleet (OS user, `Human.current!()`). Scoping multi-user : on ne dispatche
    # QUE ses issues (sinon le poller d'Alice spawne pour Bob). Seam test : opt `:human`.
    :my_human,
    :forge_client_override,
    step_dispatch?: false,
    forge_opts: [],
    loader: nil,
    workflow_map_loader: nil,
    spawner: nil,
    task_queue: nil,
    # Seam de recovery de wake threadé jusqu'à `StepDispatcher.dispatch_issue` (défaut nil → la vraie
    # `WakeRecovery.wake/3`). Rend testable le contrat « wake raté ⇒ workflow_run démarré, bail PRIS » sans hit
    # IncidentRegistry/tmux réels.
    wake_recovery: nil,
    # G6 seam : escalade d'une workflow_map illisible (défaut nil → `IncidentRegistry.record_or_escalate/4`).
    # Rend testable « map durablement absente ⇒ escalade sysadmin » sans hit le registre/forge réels.
    incident_fun: nil,
    poll_count: 0,
    error_count: 0,
    err_streak: 0,
    last_error: nil,
    # nb d'erreurs de DISPATCH (par item) du dernier tick. La liste forge
    # (`list_open_*`) peut réussir alors que des `dispatch_*` échouent — ces erreurs
    # incrémentent `err_streak` (backoff partiel via `next_delay`) au lieu d'être noyées.
    last_tally_errors: 0,
    # Réconciliation verrou : refs `{:issue|:pr, n}` vues ORPHELINES (verrou `lcars-in-flight`
    # sans pod vivant) au tick précédent. Grace 2-tick (même grace que le PodWarden) → on ne réclame qu'au 2ᵉ
    # tick consécutif (évite de déverrouiller un pod fraîchement dispatché ou en cours de mort).
    orphan_lock_suspects: MapSet.new()
  ]

  @type t :: %__MODULE__{
          repo: String.t(),
          interval_ms: pos_integer(),
          forge_client_override: module() | nil,
          step_dispatch?: boolean(),
          forge_opts: keyword(),
          loader: module() | nil,
          spawner: module() | nil,
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
    # Multi-projet : plus de `:repo` obligatoire — le poller DÉCOUVRE ses projets par topic
    # (`fleet_topic(my_human)`, repos `lcars-fleet-<human>`). `:repo` reste accepté (tests/legacy/seam)
    # mais n'est plus la source (do_poll l'écrase par itération). `my_human` = la VRAIE source requise
    # (`Human.current!()` fail-loud — un poller qui ne sait pas QUI il est ne peut pas scoper).
    state = %__MODULE__{
      repo: Keyword.get(opts, :repo),
      my_human: Keyword.get(opts, :human) || Fleet.Credentials.Human.current!(),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      forge_client_override: Keyword.get(opts, :forge_client),
      step_dispatch?: Keyword.get(opts, :step_dispatch?, false),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      loader: Keyword.get(opts, :loader),
      workflow_map_loader: Keyword.get(opts, :workflow_map_loader),
      spawner: Keyword.get(opts, :spawner),
      task_queue: Keyword.get(opts, :task_queue),
      wake_recovery: Keyword.get(opts, :wake_recovery),
      incident_fun: Keyword.get(opts, :incident_fun)
    }

    _ =
      if Keyword.get(opts, :start_tick?, true) do
        schedule(jitter(state.interval_ms))
      end

    Logger.info(
      "fleet_pilot Poller start mode=step MULTI-PROJET topic=#{fleet_topic(state.my_human)} " <>
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
  # result) ET force_poll (qui le renvoie) → force_poll ne bypasse pas le rescue.
  defp safe_poll(state) do
    do_poll(state)
  rescue
    exception -> poll_crash(state, exception, "crash")
  catch
    kind, reason -> poll_crash(state, {kind, reason}, "exit/throw")
  end

  # rescue ET catch :exit/:throw — un `GenServer.call` vers une dép morte (enqueue→TaskQueue,
  # spawn→Spawner) lève `:exit`, PAS `{:error}` ; sans le catch, la boucle crashait (≠ « state preserved »
  # annoncé). On dégrade gracieusement (err_streak + backoff, state conservé), comme
  # `Reconciliation.live_owned_refs` (un `GenServer.call` peut toujours `:exit` si la cible meurt — ne
  # jamais le laisser remonter nu).
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

  # Mode STEP uniquement (le legacy `do_poll`/Executor RAM a été retiré). Le scan est dans
  # `step_do_poll/1` ; ce wrapper conserve le point d'entrée unique (jitter/backoff/safety-net partagés).
  # Découverte forge-driven. Le poller scanne TOUS les projets de SON humain (repos
  # taggés `lcars-fleet-<human>` par l'onboarding), pas un `:repo` hard-codé. Per-repo : la logique step
  # INCHANGÉE (state.repo posé par itération). Découverte OK → forge up → err_streak reset ; le scoping
  # issue `assigned_by=my_human` reste le garde anti-vol même si un repo d'Alice fuyait.
  # Découverte KO → backoff (handle_poll_error). Le bail repo-sérialisé reste per-repo (concurrent across,
  # séquentiel within).
  #
  # Per-repo state : les erreurs de DISPATCH per-item vivent dans la TALLY (pas le streak — un repo qui
  # liste mal ne backoff PAS toute la fleet, la forge est up puisque la découverte a réussi). MAIS l'état
  # de RÉCONCILIATION (`orphan_lock_suspects`, grace 2-tick) DOIT persister cross-tick : sans le re-thread,
  # la grace ne s'accumule jamais → un verrou orphelin n'est JAMAIS réclamé (le pipe wedge). On l'agrège
  # (union sur tous les repos) dans le state rendu. `poll_count` +1/tick (observabilité).
  # Les refs de verrou sont REPO-QUALIFIÉES (`{repo, :issue|:pr, n}`, construites dans
  # `Reconciliation`) : l'union cross-repo des suspects ne collisionne plus sur le seul
  # numéro → un pod vivant #N/repoB NE masque PLUS un orphelin #N/repoA, et la grace 2-tick ne se contamine
  # plus entre repos (plus de double-spawn). La clé porte l'identité.
  defp do_poll(state) do
    forge = step_forge_client(state)

    case forge.search_repos_by_topic(fleet_topic(state.my_human), state.forge_opts) do
      {:ok, discovered} ->
        base = %{state | err_streak: 0, poll_count: state.poll_count + 1, last_error: nil}

        # FRONTIÈRE D'ADMISSION : le topic rend un repo DÉCOUVRABLE mais ne l'ADMET pas (topic mutable —
        # un propriétaire de repo peut se l'auto-poser). On ne scanne QUE les repos qui portent le sceau
        # système non forgeable (`admitted?` : marqueur `[lcars-onboarded:<human>]` posé PAR le bot, vérifié
        # server-side). Un repo tagué mais jamais onboardé par le système (le vecteur du finding) est
        # ÉCARTÉ ici, avant tout dispatch. Fail-closed : `admitted?` rend `false` sur doute (bot irrésoluble
        # / erreur de lecture) → on n'admet jamais à l'aveugle.
        repos = admitted_repos(forge, discovered, state)

        {tally, suspects} =
          Enum.reduce(repos, {zero_tally(), MapSet.new()}, fn repo, {acc_tally, acc_suspects} ->
            {t, st} = step_do_poll(%{base | repo: repo})
            {merge_tally(acc_tally, t), MapSet.union(acc_suspects, st.orphan_lock_suspects)}
          end)

        {tally, %{base | orphan_lock_suspects: suspects, last_tally_errors: tally.errors}}

      {:error, reason} ->
        handle_poll_error(state, {:discover_repos, reason}, System.monotonic_time(), nil)
    end
  end

  # Filtre les repos découverts par topic à ceux SCELLÉS par le système (`admitted?` = marqueur
  # bot-authored, même primitif de confiance que les marqueurs route/step_run). Le poller ne dispatche
  # jamais sur un repo non admis.
  #
  # Filtrage SILENCIEUX, à dessein : écarter un repo découvrable-mais-non-scellé est le fonctionnement
  # NOMINAL de la frontière (fail-closed), ré-évalué à CHAQUE tick (~30s) — pas un événement. Le logger
  # (en warning, qui plus est) crachait une ligne par repo écarté par tick : un repo tagué mais jamais
  # onboardé reste écarté indéfiniment → des centaines de warnings d'un état stable qui noient la trace.
  # Un repo réellement « à finir d'onboarder » se constate sur la forge (repos portant le topic sans le
  # sceau), pas dans le log de poll. Seules les ERREURS de découverte/dispatch sont loggées
  # (handle_poll_error) ; un filtrage de routine est muet.
  defp admitted_repos(forge, discovered, state) do
    Enum.filter(discovered, fn repo ->
      forge.admitted?(repo, state.my_human, state.forge_opts)
    end)
  end

  @doc """
  Topic forge per-humain des projets de la fleet : `lcars-fleet-<human-sanitisé>`. **Source UNIQUE**
  partagée par l'onboarding (qui TAGUE le repo neuf) et le poller (qui DÉCOUVRE). Sanitize Gitea-topic
  (lowercase, `[a-z0-9-]`). C'est l'axe d'isolation REPO (Alice ne découvre pas les projets de Bob) ;
  l'axe ISSUE (`assigned_by`) est la ceinture.
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
  # Mode STEP — réacteur assignee-driven (la forge EST la machine à états ; ce module en est le réacteur).
  # Découplé du legacy AutoDispatcher : pas de routes, pas d'Executor.
  # ============================================================

  defp step_do_poll(state) do
    started = System.monotonic_time()
    forge = step_forge_client(state)

    # Bail repo-sérialisé : on liste TOUS les ouverts (in-flight inclus) pour compter les
    # workflow_runs actifs. On liste AUSSI les PR ouvertes → les JUGES sont dispatchés
    # via les requested_reviewers de la PR (plus l'assignee issue). decide skip les in-flight.
    # Scoping multi-user FORGE-SIDE : MÊME filtre `assigned_by` pour issues ET PR (les deux passent
    # par /issues?type=… côté ForgeClient). Le poller ne voit QUE les items de SON humain → le scoping vit en
    # UN endroit (la liste), decide/dispatch_review ne re-vérifient plus l'ownership. Bail par-humain.
    scoped_opts = Keyword.put(state.forge_opts, :assigned_by, state.my_human)

    with {:ok, issues} <- forge.list_open_issues(state.repo, scoped_opts),
         {:ok, pulls} <- forge.list_open_pulls(state.repo, scoped_opts) do
      pr_issue_ids = pulls_issue_ids(pulls)

      # Réconciliation verrou AVANT dispatch : un `lcars-in-flight` orphelin (pod mort sans avoir
      # complété → reapé, mais le label survit côté forge) bloquerait la brique pour TOUJOURS
      # (`dispatch_*` skip `:in_flight`). On le réclame (grace 2-tick) → le prochain tick re-dispatche.
      # Sans ça, un seul stall de pod wedge le pipe définitivement. La DÉCISION vit dans
      # `Reconciliation` (lit 5 seams, rend le set de suspects) ; la grâce 2-tick (`prior_suspects`) et
      # l'union cross-repo restent ICI (état cross-tick). On résout les défauts prod des seams à CE site.
      reconciliation_seams = %Reconciliation.Seams{
        forge: forge,
        spawner: state.spawner || Fleet.Spawner,
        task_queue: state.task_queue || Fleet.TaskQueue,
        repo: state.repo,
        forge_opts: state.forge_opts
      }

      new_suspects =
        Reconciliation.reconcile(
          issues,
          pulls,
          pr_issue_ids,
          state.orphan_lock_suspects,
          reconciliation_seams
        )

      # opts de dispatch calculées UNE fois/tick (partagées issues + pulls), pas 2×.
      opts = step_dispatch_opts(state)

      # SET des issues `lcars-awaits-arch` (déjà listées au tick → ZÉRO I/O ajouté), threadé
      # aux pulls via `:awaits_arch_ids` → `dispatch_review` skippe le juge d'une PR dont l'issue parente
      # attend l'arch (symétrique de `decide/1` côté issue). Sans ça : l'escalade pose `awaits-arch` sur
      # l'ISSUE mais `dispatch_review` ne lit QUE les labels de la PR → re-spawn du juge par tick (churn).
      awaits_arch_ids = awaits_arch_ids(issues)
      pulls_opts = Keyword.put(opts, :awaits_arch_ids, awaits_arch_ids)

      # G4 : re-kick throttlé de l'arch tant qu'une issue attend son action (le kick initial à l'escalade
      # est one-shot ; wake perdu → issue bloquée pour toujours sinon).
      maybe_rekick_arch(awaits_arch_ids, state)

      tally =
        merge_tally(
          step_process_issues(issues, pr_issue_ids, state, opts),
          step_process_pulls(pulls, pulls_opts)
        )

      duration_ms = elapsed_ms(started)

      # Tick réussi = SILENCIEUX. Ce poll est un cron ~30s en boucle ; logger chaque passage nominal
      # (le plus souvent dispatched=0, rien à faire) noie la trace sous des centaines de lignes de
      # routine. Les métriques (durée, dispatched/skipped/errors) partent en telemetry ci-dessous ;
      # les échecs de poll sont loggés (handle_poll_error) et chaque dispatch per-item se trace à son
      # niveau. On loggue quand ça plante, pas quand ça tourne.
      :telemetry.execute(
        [:fleet_pilot, :poller, :poll],
        %{duration_ms: duration_ms},
        Map.merge(tally, %{status: :ok, mode: :step, repo: state.repo})
      )

      # La liste forge a réussi, mais des `dispatch_*` PAR ITEM ont pu échouer
      # (`tally.errors > 0` — ex. enqueue broker KO, spawn KO). Si `err_streak` était remis à 0
      # inconditionnellement, ces erreurs ne ralentiraient JAMAIS le poller (il martèlerait la
      # forge au plein régime malgré l'échec). On réutilise le mécanisme `err_streak`/`next_delay`
      # (backoff partiel) : streak incrémenté tant que des items échouent, reset à 0 seulement
      # quand le tick est propre.
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

  # SET des numéros d'issue portant `lcars-awaits-arch`. Dérivé des `issues` DÉJÀ listées
  # par le tick (aucun appel forge supplémentaire) → threadé aux pulls (`:awaits_arch_ids`) pour que
  # `dispatch_review` skippe le juge d'une PR dont l'issue parente attend l'arch.
  defp awaits_arch_ids(issues) do
    for i <- issues, n = i["number"], awaits_arch?(i), into: MapSet.new(), do: n
  end

  # G4 — RE-KICK de l'arch tant qu'au moins une issue attend son action (`lcars-awaits-arch`). Le kick
  # initial (à l'escalade, StepRunConsumer.kick_architect) est one-shot best-effort : si le wake s'est
  # perdu (arch occupé, ou mort-puis-respawné par le PermanentWarden), l'issue reste hors-dispatch POUR
  # TOUJOURS, silencieusement (le poller ne fait que la SKIPPER). On re-kicke donc périodiquement —
  # THROTTLÉ (`@awaits_rekick_every` ticks) car un wake peut coûter un tour claude (dépense bornée,
  # Jupiter). Best-effort (le label reste human-released : on nudge le sas, on ne force jamais le verdict).
  # Réutilise le seam `spawner` (défaut `Fleet.Spawner`) + l'autorité `Roles.architect_pod_id/0` (SSOT
  # partagée avec kick_architect). nil spawner (test/config) → no-op.
  defp maybe_rekick_arch(awaits_ids, %__MODULE__{spawner: spawner} = state)
       when not is_nil(spawner) do
    if awaits_rekick?(MapSet.size(awaits_ids), state.poll_count) do
      pod_id = Fleet.Pilot.Roles.architect_pod_id()

      Logger.info(
        "Poller: #{MapSet.size(awaits_ids)} issue(s) awaits-arch → re-kick #{pod_id} " <>
          "(throttle #{@awaits_rekick_every} ticks)"
      )

      _ = spawner.wake_pod(pod_id)
    end

    :ok
  end

  defp maybe_rekick_arch(_awaits_ids, _state), do: :ok

  @doc false
  # Décision PURE du re-kick : au moins UNE issue attend l'arch ET on est sur un tick multiple du
  # throttle. Exposé (test) — le calcul est le cœur load-bearing (le wake, lui, est une délégation seam).
  @spec awaits_rekick?(non_neg_integer(), non_neg_integer()) :: boolean()
  def awaits_rekick?(awaits_size, poll_count)
      when is_integer(awaits_size) and is_integer(poll_count) do
    awaits_size > 0 and rem(poll_count, @awaits_rekick_every) == 0
  end

  defp awaits_arch?(item) do
    @awaits_arch in Enum.map(Map.get(item, "labels") || [], & &1["name"])
  end

  # Issues portant une PR fleet ouverte (`lcars/issue-N-role`) = workflow_runs en phase JUGE :
  # le producteur a fini, la suite est dispatchee via les pulls -> le chemin issue les SKIP
  # (sinon le poller re-spawnerait le producteur, encore assigne).
  defp pulls_issue_ids(pulls) do
    pulls
    |> Enum.flat_map(fn pr ->
      case Fleet.Pilot.ForgeProtocol.parse_feature_branch(get_in(pr, ["head", "ref"]) || "") do
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

  # Tally vierge (source unique). Les chemins d'erreur utilisent `%{zero_tally() | errors: 1}`.
  defp zero_tally, do: %{dispatched: 0, skipped: 0, errors: 0}

  # Chemin PR-driven : chaque PR ouverte avec une review demandée → dispatch le juge.
  # Non gardé par le bail (les juges d'un workflow_run DÉJÀ actif doivent avancer ; le bail ne borne
  # que l'ENTRÉE de nouveaux workflow_runs, côté issues).
  defp step_process_pulls(pulls, opts) do
    Enum.reduce(pulls, zero_tally(), fn pr, acc ->
      case StepDispatcher.dispatch_review(pr, opts) do
        # `:ok` couvre `{:spawned, _, _}` (juge/rework spawné) ET `{:merged, _}` (PR scellée).
        {:ok, _} -> %{acc | dispatched: acc.dispatched + 1}
        {:skipped, _reason} -> %{acc | skipped: acc.skipped + 1}
        {:error, _reason} -> %{acc | errors: acc.errors + 1}
      end
    end)
  end

  defp step_process_issues(issues, pr_issue_ids, state, opts) do
    # Cohérence : le routing vit dans la ROUTE-COMMENT (state-machine, gravée à l'onboard) — plus de
    # routing par label. Le poller lit la route → dispatch (workflow_map_role). Le bail « 1 workflow_run actif/repo »
    # se lit AUSSI sur la route (robuste, append-only). On classe chaque issue UNE fois :
    #   - ENGAGÉ (in-flight, ou route avancée au-delà du 1er step = workflow_run démarré) → tient le bail ;
    #     on dispatche son step courant (continue le step_run, ou skip si in-flight).
    #   - EN FILE (routée au 1er step, ou routeless à onboarder, pas encore dispatchée) → démarre seulement
    #     si le bail est libre ; sinon attend (sérialisation → feature-branches séquentielles → FF merge).
    # `classify_issue` lit la route (+ charge la workflow_map) UNE fois et la THREAD au dispatch via
    # `prefetch` (mergé aux opts) → fin du double get_route / double load workflow_map (la classif du bail et le
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
            # Issue avec PR fleet ouverte → phase JUGE (dispatchée via les pulls). SKIP côté
            # issue (sinon re-spawn du producteur). La PR tient le bail.
            pr? ->
              {%{acc | skipped: acc.skipped + 1}, lease}

            # Pipeline ENGAGÉ → dispatche son step courant ; il DÉTIENT le bail → lease inchangé.
            engaged ->
              dispatch_engaged(payload, item_opts, acc, lease)

            # EN FILE, bail tenu par un autre workflow_run → attend.
            lease ->
              {%{acc | skipped: acc.skipped + 1}, lease}

            # EN FILE, bail libre → DÉMARRE (prend le bail si effectivement dispatché).
            true ->
              start_workflow_run(payload, item_opts, acc)
          end
      end)

    tally
  end

  # Dispatch d'un item + mise à jour du tally ET du bail. Deux concerns DISTINCTS, que le retour de
  # `dispatch_issue` mélange :
  #
  #   * BAIL — le workflow_run a-t-il DÉMARRÉ (pod spawné + verrou `lcars-in-flight` posé) ? L'ordre canonique
  #     du spawn (`StepDispatcher.spawn_step`) est verrou → pod → enqueue → WAKE, le wake EN DERNIER. Donc
  #     `{:error, {:wake_unreached, …}}` veut dire : le workflow_run EST démarré (verrou + pod + brief en place),
  #     SEUL le réveil tmux a raté. Le workflow_run tient donc le bail repo-sérialisé — sinon un 2e issue du même
  #     repo dans le même tick démarrerait un 2e workflow_run (deux feature-branches concurrentes → conflit de merge).
  #   * TALLY/backoff — y a-t-il une anomalie à SURFACER ? Le wake raté reste compté en `errors` (il alimente
  #     `err_streak`/telemetry → backoff partiel) : un kick injoignable ne doit PAS être avalé en succès
  #     silencieux (le pod ne tourne pas tant qu'il n'est pas réveillé).
  #
  # D'où le 3ᵉ cas `wake_unreached` = (démarré pour le BAIL, anomalie pour le TALLY). On retourne
  # `{tally, started?}` ; `started?` (= un pod a réellement été mis en vol ce tick) pilote la prise de bail,
  # INDÉPENDAMMENT du fait que le dispatch ait fini sans erreur.
  defp step_do_dispatch(payload, opts, acc) do
    case StepDispatcher.dispatch_issue(payload, opts) do
      {:ok, {:spawned, _pod_id, _role}} ->
        {%{acc | dispatched: acc.dispatched + 1}, true}

      # Pipeline DÉMARRÉ (verrou + pod + brief posés) mais wake injoignable. Le bail est PRIS (started?
      # = true) ; l'anomalie reste comptée en `errors` (backoff + telemetry honnêtes, jamais avalée).
      {:error, {:wake_unreached, _pod_id, _role, _reason}} ->
        {%{acc | errors: acc.errors + 1}, true}

      {:skipped, _reason} ->
        {%{acc | skipped: acc.skipped + 1}, false}

      # Vrai échec de dispatch (rien démarré — la compensation a retiré le verrou + tué le pod frais) → bail LIBRE.
      {:error, _reason} ->
        {%{acc | errors: acc.errors + 1}, false}
    end
  end

  # Dispatch d'un workflow_run ENGAGÉ (il tient DÉJÀ le bail) : le bail reste inchangé quoi qu'il arrive
  # (le tally est mis à jour, `started?` est ignoré — l'engagement vient de la classification, pas de ce step_run).
  defp dispatch_engaged(payload, opts, acc, lease) do
    {acc2, _started?} = step_do_dispatch(payload, opts, acc)
    {acc2, lease}
  end

  # Démarrage d'un workflow_run EN FILE (bail libre) : dispatch ; si un pod a effectivement été mis en vol
  # (spawné OU wake_unreached = verrou+pod posés), le bail devient TENU → les autres issues en file du même
  # tick attendent (sérialisation 1 workflow_run/repo). Un wake raté tient le bail (le workflow_run est démarré),
  # PAS un échec de dispatch (rien démarré).
  defp start_workflow_run(payload, opts, acc) do
    {acc2, started?} = step_do_dispatch(payload, opts, acc)
    {acc2, started?}
  end

  # Classifie une issue (bail) ET pré-résout ce que `dispatch_issue` relirait sinon. Renvoie
  # `{engaged?, prefetch_kw}` ; `prefetch_kw` (mergé aux opts de dispatch) porte `:prefetched_route` +
  # `:prefetched_workflow_map` → lecture forge/disque UNE seule fois. ENGAGÉ = pod en vol (`in-flight`) OU route
  # avancée au-delà du 1er step (workflow_run démarré, entre deux step_runs). Fast-path : in-flight → pas de lecture
  # route (`decide` le skip de toute façon). Routeless (`:none`) → EN FILE, route nil threadée (onboard en
  # aval). Erreur HTTP get_route → EN FILE, RIEN threadé (le dispatch re-lit → fail-loud `:route_resolution`,
  # jamais de wedge du bail par une workflow_map/route illisible).
  defp classify_issue(_issue, true = _pr?, _state), do: {false, []}

  defp classify_issue(issue, false = _pr?, state) do
    labels = Enum.map(Map.get(issue, "labels") || [], & &1["name"])

    if @in_flight in labels do
      {true, []}
    else
      forge = step_forge_client(state)
      n = Map.get(issue, "number")

      case forge.get_route(state.repo, n, state.forge_opts) do
        {:ok, {workflow_map_name, step} = route}
        when is_binary(workflow_map_name) and is_binary(step) ->
          # Le bail se lit sur la ROUTE (append-only, robuste), JAMAIS sur le succès du chargement de la
          # workflow_map. Une route PRÉSENTE = un workflow_run déjà entré dans la machine. ENGAGÉ ssi le step courant
          # n'est pas le 1er de la workflow_map (workflow_run avancé entre deux step_runs). Si la workflow_map échoue à charger
          # TRANSITOIREMENT (réseau/forge nil), on NE PEUT PAS exclure que ce workflow_run soit avancé → fail-closed :
          # on le classe ENGAGÉ (bail TENU). Sinon une workflow_map-nil ferait perdre le bail d'un workflow_run engagé →
          # un 2e issue du même repo démarrerait un 2e workflow_run (perte de sérialisation). Le dispatch de SON
          # step fail-loud si la workflow_map manque (workflow_map re-lue côté StepDispatcher), mais le bail NE se libère
          # pas pour autant. WorkflowMap revenue au tick suivant → classification précise reprise.
          workflow_map = load_workflow_map_or_nil(workflow_map_name, state)
          engaged = is_nil(workflow_map) or not first_step?(workflow_map, step)
          {engaged, [prefetched_route: route, prefetched_workflow_map: workflow_map]}

        :none ->
          {false, [prefetched_route: nil]}

        _ ->
          {false, []}
      end
    end
  end

  # Charge la workflow_map (seam `workflow_map_loader` ou Loader réel) ; `nil` sur échec (le dispatch re-tentera → fail-loud).
  defp load_workflow_map_or_nil(workflow_map_name, state) do
    loader = state.workflow_map_loader || Fleet.Workflow.Loader
    loader.load!(workflow_map_name)
  rescue
    e ->
      # G6 : la workflow_map ne charge PAS (retirée/renommée du catalogue, ou schema cassé). Le bail reste
      # fail-closed (cf. classify_issue : on ne libère pas le bail d'un workflow_run peut-être avancé) — MAIS
      # si l'absence est DURABLE, l'issue tient le bail et le repo est bloqué POUR TOUJOURS en silence
      # (Jupiter : personne ne le verra). On ESCALADE : IncidentRegistry dédup par signature → 1ère
      # occurrence = note WAL, RÉCURRENCE (map absente à chaque tick) = issue sysadmin ouverte. Pas de spam
      # (le dédup EST le throttle). Best-effort (l'escalade ne doit jamais casser le tick).
      _ = escalate_workflow_map_incident(workflow_map_name, Exception.message(e), state)
      nil
  end

  defp escalate_workflow_map_incident(workflow_map_name, message, state) do
    fun = state.incident_fun || (&Fleet.Pilot.IncidentRegistry.record_or_escalate/4)

    fun.(
      "workflow_map_load",
      workflow_map_name,
      {:workflow_map_load_failed, message},
      forge_opts: state.forge_opts
    )
  rescue
    # L'escalade elle-même ne doit JAMAIS faire tomber le tick (registre down, etc.).
    _ -> :escalation_skipped
  end

  # Le step est-il le 1er de la workflow_map (= routé mais pas avancé = EN FILE) ? Anomalie workflow_map → `true`
  # (traité « non engagé » : le dispatch fail-loud surfacera, jamais de wedge du bail par une workflow_map illisible).
  defp first_step?(workflow_map, step) do
    case Fleet.Pilot.WorkflowMapNav.first_step(workflow_map) do
      {:ok, {first, _role}} -> step == first
      _ -> true
    end
  end

  # Construit les opts de StepDispatcher.dispatch_issue. Les seams
  # (loader/spawner/task_queue) ne sont injectés QUE s'ils sont set sur le
  # state — sinon StepDispatcher applique ses défauts réels (passer nil
  # écraserait le défaut).
  # `:task_queue` est porté par le state (résolu au site d'appel de `Reconciliation.reconcile`) et DOIT
  # être transmis ici, sinon StepDispatcher retombe sur `Fleet.TaskQueue` global pour l'enqueue du brief
  # (seam de broker non honoré côté dispatch).
  defp step_dispatch_opts(state) do
    [
      repo: state.repo,
      forge_client: step_forge_client(state),
      forge_opts: state.forge_opts
    ]
    |> Opts.maybe_put(:loader, state.loader)
    # `workflow_map_role` (dispatch) charge la workflow_map de la route → il lui faut le loader de WORKFLOW_MAP (comme
    # fonction load!/1). Live : nil → défaut `Fleet.Workflow.Loader.load!` (priv). Test : dérivé du module
    # stub. (Distinct de `:loader` = cap-profiles.)
    |> Opts.maybe_put(:workflow_map_loader, workflow_map_loader_fun(state))
    |> Opts.maybe_put(:spawner, state.spawner)
    |> Opts.maybe_put(:task_queue, state.task_queue)
    # Threadé jusqu'à `dispatch_issue` : seul nil retombe sur le défaut réel (la vraie `WakeRecovery.wake/3`).
    |> Opts.maybe_put(:wake_recovery, state.wake_recovery)
  end

  defp workflow_map_loader_fun(%__MODULE__{workflow_map_loader: nil}), do: nil

  defp workflow_map_loader_fun(%__MODULE__{workflow_map_loader: cl}),
    do: fn name -> cl.load!(name) end

  defp step_forge_client(%__MODULE__{forge_client_override: nil}), do: Fleet.Pilot.ForgeClient
  defp step_forge_client(%__MODULE__{forge_client_override: fc}), do: fc

  defp elapsed_ms(started_native) do
    System.convert_time_unit(
      System.monotonic_time() - started_native,
      :native,
      :millisecond
    )
  end
end
