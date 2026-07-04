defmodule Fleet.Pilot.Poller.Lease do
  @moduledoc """
  Bail repo-sérialisé du rail step (extrait de `Fleet.Pilot.Poller`) : **au plus UN
  workflow_run actif par repo**. Classe chaque issue du tick (ENGAGÉ / EN FILE), puis
  dispatche sous ce bail — les feature-branches restent séquentielles → merge FF garanti.

  ## La décision (cœur métier)

    * **ENGAGÉ** = pod en vol (`lcars-in-flight`) OU route gravée avancée au-delà du 1er
      step (workflow_run démarré, entre deux step_runs) → il TIENT le bail ; on
      dispatche son step courant (continue), jamais un 2e départ.
    * **EN FILE** = routée au 1er step, ou routeless (à onboarder) → ne DÉMARRE que si
      le bail est libre ; sinon attend le prochain tick (sérialisation).
    * Le bail se lit sur la ROUTE (append-only, robuste), JAMAIS sur le succès du
      chargement de la workflow_map : une workflow_map illisible TRANSITOIREMENT ne peut
      pas exclure un workflow_run avancé → **fail-closed** (classé ENGAGÉ, bail TENU).
      Absence DURABLE → escalade G6 (IncidentRegistry, dédup = throttle) — jamais un
      repo bloqué en silence.

  ## Bail vs tally — deux concerns que le retour de dispatch mélange

  L'ordre canonique du spawn est verrou → pod → enqueue → WAKE (le wake EN DERNIER) :
  `{:error, {:wake_unreached, …}}` signifie que le workflow_run EST démarré (bail PRIS)
  mais l'anomalie reste comptée en `errors` (backoff partiel + telemetry — un kick
  injoignable n'est jamais avalé en succès silencieux). D'où le retour interne
  `{tally, started?}` : `started?` pilote le bail INDÉPENDAMMENT de l'erreur.

  ## Frontière blindée

  `Seams` (struct étroit, défauts prod résolus AU SITE de construction — même règle que
  `Reconciliation.Seams`) : le cluster ne lit jamais le state du poller. L'état
  cross-tick (grâce 2-tick des orphelins, err_streak) reste au GenServer.

  Ce module possède aussi le vocabulaire du **tally** (`zero_tally/0`, `merge_tally/2`)
  — la monnaie d'observabilité du tick, produite ici et agrégée par le poller.
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher

  # Verrou workflow_run (source unique `Fleet.Pilot.Labels`) — fast-path `classify_issue`
  # (in-flight → ENGAGÉ sans lecture de route).
  @in_flight Fleet.Pilot.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Frontière blindée du bail : les SEULES lectures que `Lease` peut faire. Les défauts
    prod (`Fleet.Workflow.Loader`, `IncidentRegistry.record_or_escalate/4`) sont résolus
    par le poller AU SITE de construction — ici, tout est déjà concret.
    """
    @enforce_keys [:forge, :repo, :forge_opts, :workflow_map_loader, :incident_fun]
    defstruct [
      # Client forge (module concret — l'override test est résolu en amont).
      :forge,
      # Repo "owner/name" de l'itération courante du scan multi-projet.
      :repo,
      # Opts forge (base_url, token…).
      :forge_opts,
      # Loader de workflow_map (module .load!/1) — jamais nil ici.
      :workflow_map_loader,
      # Escalade G6 d'une workflow_map illisible (arity 4) — jamais nil ici.
      :incident_fun
    ]

    @type t :: %__MODULE__{
            forge: module(),
            repo: String.t(),
            forge_opts: keyword(),
            workflow_map_loader: module(),
            incident_fun: (String.t(), String.t(), term(), keyword() -> term())
          }
  end

  @typedoc "Compteurs d'un tick : items dispatchés / skippés / en erreur."
  @type tally :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc "Tally vierge (source unique). Les chemins d'erreur utilisent `%{zero_tally() | errors: 1}`."
  @spec zero_tally() :: tally()
  def zero_tally, do: %{dispatched: 0, skipped: 0, errors: 0}

  @doc "Somme champ à champ de deux tallies (agrégation issues+pulls, cross-repo)."
  @spec merge_tally(tally(), tally()) :: tally()
  def merge_tally(a, b) do
    %{
      dispatched: a.dispatched + b.dispatched,
      skipped: a.skipped + b.skipped,
      errors: a.errors + b.errors
    }
  end

  @doc """
  Classe puis dispatche les issues du tick sous le bail repo-sérialisé. `pr_issue_ids` =
  issues portant une PR fleet ouverte (phase JUGE, dispatchées via les pulls → SKIP côté
  issue, la PR tient le bail). `dispatch_opts` = opts de `StepDispatcher.dispatch_issue`
  (préparées une fois par tick par le poller). Rend le tally du chemin issues.
  """
  @spec process_issues([map()], MapSet.t(), keyword(), Seams.t()) :: tally()
  def process_issues(issues, pr_issue_ids, dispatch_opts, %Seams{} = seams) do
    # Cohérence : le routing vit dans la ROUTE-COMMENT (state-machine, gravée à l'onboard) — plus de
    # routing par label. On lit la route → dispatch (workflow_map_role). Le bail « 1 workflow_run actif/repo »
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
        {engaged, prefetch} = classify_issue(issue, pr?, seams)
        {issue, pr?, engaged, prefetch}
      end)

    lease_held0 = Enum.any?(classified, fn {_issue, _pr?, engaged, _pf} -> engaged end)

    {tally, _lease} =
      Enum.reduce(classified, {zero_tally(), lease_held0}, fn
        {issue, pr?, engaged, prefetch}, {acc, lease} ->
          payload = wrap_issue_as_payload(issue, seams.repo)
          item_opts = Keyword.merge(dispatch_opts, prefetch)

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
  defp classify_issue(_issue, true = _pr?, _seams), do: {false, []}

  defp classify_issue(issue, false = _pr?, seams) do
    labels = Enum.map(Map.get(issue, "labels") || [], & &1["name"])

    if @in_flight in labels do
      {true, []}
    else
      n = Map.get(issue, "number")

      case seams.forge.get_route(seams.repo, n, seams.forge_opts) do
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
          workflow_map = load_workflow_map_or_nil(workflow_map_name, seams)
          engaged = is_nil(workflow_map) or not first_step?(workflow_map, step)
          {engaged, [prefetched_route: route, prefetched_workflow_map: workflow_map]}

        :none ->
          {false, [prefetched_route: nil]}

        _ ->
          {false, []}
      end
    end
  end

  # Charge la workflow_map ; `nil` sur échec (le dispatch re-tentera → fail-loud).
  defp load_workflow_map_or_nil(workflow_map_name, seams) do
    # R4 : le rescue vit dans l'autorité unique (WorkflowMapNav.safe_load) ; CE site garde sa
    # sémantique propre (nil = bail fail-closed + escalade G6 ci-dessous).
    case Fleet.Pilot.WorkflowMapNav.safe_load(seams.workflow_map_loader, workflow_map_name) do
      {:ok, map} ->
        map

      {:error, {:workflow_map_load_failed, _name, message}} ->
        # G6 : la workflow_map ne charge PAS (retirée/renommée du catalogue, ou schema cassé). Le bail
        # reste fail-closed (cf. classify_issue : on ne libère pas le bail d'un workflow_run peut-être
        # avancé) — MAIS si l'absence est DURABLE, l'issue tient le bail et le repo est bloqué POUR
        # TOUJOURS en silence (Jupiter : personne ne le verra). On ESCALADE : IncidentRegistry dédup
        # par signature → 1ère occurrence = note WAL, RÉCURRENCE (map absente à chaque tick) = issue
        # sysadmin ouverte. Pas de spam (le dédup EST le throttle). Best-effort (l'escalade ne doit
        # jamais casser le tick).
        _ = escalate_workflow_map_incident(workflow_map_name, message, seams)
        nil
    end
  end

  defp escalate_workflow_map_incident(workflow_map_name, message, seams) do
    seams.incident_fun.(
      "workflow_map_load",
      workflow_map_name,
      {:workflow_map_load_failed, message},
      forge_opts: seams.forge_opts
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

  # Forme payload attendue par `StepDispatcher.dispatch_issue` (l'issue + son repo d'origine).
  defp wrap_issue_as_payload(issue, repo) do
    %{
      "issue" => issue,
      "repository" => %{"full_name" => repo}
    }
  end
end
