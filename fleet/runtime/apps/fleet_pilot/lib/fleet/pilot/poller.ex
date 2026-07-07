defmodule Fleet.Pilot.Poller do
  @moduledoc """
  Réacteur du rail forge-state-machine (**mode STEP uniquement**), **multi-projet** : à chaque
  tick il DÉCOUVRE les repos de son humain par topic forge (`lcars-fleet-<humain>`), puis délègue
  les issues + PR ouvertes au spawn des rôles via `StepDispatcher`.

  ## Rôle

  La forge EST la machine à états ; ce poller en est le réacteur. À chaque tick, pour CHAQUE repo
  découvert par le topic, il liste les **issues** + **PR** ouvertes et délègue :

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

  ## Sous-modules

    * `Backoff` — calcul PUR du délai (jitter + backoff exponentiel) ; le GenServer garde
      l'effet (`schedule/1`) et le rescue (`safe_poll`).
    * `Lease` — bail repo-sérialisé (classification ENGAGÉ/EN FILE + dispatch sous bail,
      chemin issues) ; frontière blindée `Lease.Seams`, vocabulaire du tally.
    * `Reconciliation` — réclamation des verrous `lcars-in-flight` orphelins (la grâce
      2-tick — état cross-tick — reste ICI, `orphan_lock_suspects`).

  Restent ICI : la boucle (découverte topic + admission + orchestration tally + backoff
  d'état), le chemin pulls (`step_process_pulls`, non gardé par le bail) et le re-kick
  awaits-arch throttlé (couplé à `poll_count`).

  ## Configuration init

    * `:repo` — `"owner/name"`, OPTIONNEL (seam test/legacy) : plus la source des repos —
      la découverte par topic l'écrase à chaque itération de `do_poll`.
    * `:human` — seam test ; défaut `Fleet.Credentials.Human.current!()` (fail-loud), la
      VRAIE source requise du scoping multi-user.
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

  # Timing PUR du tick (jitter anti-herd + backoff exponentiel capé) — le GenServer garde
  # l'EFFET (`schedule/1` = Process.send_after) et le rescue (`safe_poll`), Backoff rend le délai.
  alias Fleet.Pilot.Poller.Backoff

  # Bail repo-sérialisé (classification ENGAGÉ/EN FILE + dispatch sous bail) — le CŒUR métier du
  # chemin issues, extrait. Frontière blindée : lit un `Lease.Seams` étroit (`lease_seams/1`), défauts
  # prod résolus ICI. Possède aussi le vocabulaire du tally (`zero_tally/merge_tally`).
  alias Fleet.Pilot.Poller.Lease

  # Verrou HUMAIN posé sur l'ISSUE à l'escalade (verdict gatekeeper escalate/halt/redirect, ou conflit non
  # résolu). Le poller calcule le SET des issues qui le portent (déjà listées au tick → zéro I/O) et le thread
  # aux pulls → `dispatch_review` skippe le juge d'une PR dont l'issue parente attend l'arch.
  @awaits_arch Fleet.Pilot.Labels.awaits_arch()

  @default_interval_ms 30_000

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
    # L'org forge = LA frontière d'admission (WS3) : le poller découvre par `list_org_repos(org)`, tout repo
    # de l'org EST un projet fleet. Défaut `fleet` (config `:fleet_pilot, :fleet_org`) ; DOIT matcher l'org de
    # create_project (`:fleet_mcp, :delegation_org`) — les deux défautent à `fleet`. Seam test : opt `:org`.
    :org,
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
    # Multi-projet : plus de `:repo` obligatoire — le poller DÉCOUVRE ses projets par APPARTENANCE-ORG
    # (`list_org_repos(org)`, WS3 : tout repo de l'org fleet EST un projet fleet). `:repo` reste accepté
    # (tests/legacy/seam) mais n'est plus la source (do_poll l'écrase par itération). `my_human` = la VRAIE
    # source de SCOPING requise (`Human.current!()` fail-loud — un poller qui ne sait pas QUI il est ne peut
    # pas scoper ses issues via `assigned_by`).
    state = %__MODULE__{
      repo: Keyword.get(opts, :repo),
      my_human: Keyword.get(opts, :human) || Fleet.Credentials.Human.current!(),
      org: Keyword.get(opts, :org) || Application.get_env(:fleet_pilot, :fleet_org, "fleet"),
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
        schedule(Backoff.jitter(state.interval_ms))
      end

    Logger.info(
      "Poller: start mode=step MULTI-PROJET org=#{state.org} human=#{state.my_human} " <>
        "interval=#{state.interval_ms}ms jitter=±10%"
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {_result, new_state} = safe_poll(state)
    schedule(Backoff.next_delay(new_state.err_streak, new_state.interval_ms))
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
      "Poller: unexpected #{kind_label} in do_poll: #{inspect(detail)} — state preserved"
    )

    {%{Lease.zero_tally() | errors: 1},
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

    case forge.list_org_repos(state.org, state.forge_opts) do
      {:ok, repos} ->
        base = %{state | err_streak: 0, poll_count: state.poll_count + 1, last_error: nil}

        # ADMISSION = APPARTENANCE-ORG (WS3) : tout repo de l'org EST un projet fleet — l'org est LA frontière
        # du groupe de confiance, gérée EN AMONT par l'admin humain (LCARS n'est pas du multi-tenant
        # adversarial). Plus de topic mutable ni de sceau server-side à vérifier. Le scoping per-humain reste
        # `assigned_by` (issue-level, `step_do_poll`) : la fleet ne traite QUE ses issues, même si
        # `list_org_repos` lui montre les repos des AUTRES humains du groupe (le garde anti-vol tient).
        {tally, suspects} =
          Enum.reduce(repos, {Lease.zero_tally(), MapSet.new()}, fn repo,
                                                                    {acc_tally, acc_suspects} ->
            {t, st} = step_do_poll(%{base | repo: repo})
            {Lease.merge_tally(acc_tally, t), MapSet.union(acc_suspects, st.orphan_lock_suspects)}
          end)

        {tally, %{base | orphan_lock_suspects: suspects, last_tally_errors: tally.errors}}

      {:error, reason} ->
        handle_poll_error(state, {:discover_repos, reason}, System.monotonic_time(), nil)
    end
  end

  defp handle_poll_error(state, reason, started, _err) do
    new_streak = state.err_streak + 1

    Logger.warning(
      "Poller: error repo=#{state.repo} reason=#{inspect(reason)} streak=#{new_streak}"
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

    {%{Lease.zero_tally() | errors: 1},
     %{
       state
       | error_count: state.error_count + 1,
         err_streak: new_streak,
         last_error: inspect(reason)
     }}
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
        Lease.merge_tally(
          Lease.process_issues(issues, pr_issue_ids, opts, lease_seams(state)),
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

  # Chemin PR-driven : chaque PR ouverte avec une review demandée → dispatch le juge.
  # Non gardé par le bail (les juges d'un workflow_run DÉJÀ actif doivent avancer ; le bail ne borne
  # que l'ENTRÉE de nouveaux workflow_runs, côté issues).
  defp step_process_pulls(pulls, opts) do
    Enum.reduce(pulls, Lease.zero_tally(), fn pr, acc ->
      case StepDispatcher.dispatch_review(pr, opts) do
        # `:ok` couvre `{:spawned, _, _}` (juge/rework spawné) ET `{:merged, _}` (PR scellée).
        {:ok, _} -> %{acc | dispatched: acc.dispatched + 1}
        {:skipped, _reason} -> %{acc | skipped: acc.skipped + 1}
        {:error, _reason} -> %{acc | errors: acc.errors + 1}
      end
    end)
  end

  # Frontière blindée vers `Lease` (bail repo-sérialisé) : les 5 lectures autorisées, défauts
  # prod résolus ICI (même règle que `Reconciliation.Seams` : on résout au site de construction).
  defp lease_seams(state) do
    %Lease.Seams{
      forge: step_forge_client(state),
      repo: state.repo,
      forge_opts: state.forge_opts,
      workflow_map_loader: state.workflow_map_loader || Fleet.Workflow.Loader,
      incident_fun: state.incident_fun || (&Fleet.Pilot.IncidentRegistry.record_or_escalate/4)
    }
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
