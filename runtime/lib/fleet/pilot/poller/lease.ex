defmodule Fleet.Pilot.Poller.Lease do
  @moduledoc """
  ADMISSION of the step rail, per human on each repo: at most `Admission.max_fan/2` active
  workflow_runs of this human on the repo — the project's declaration if it made one, else the
  fleet default (**5**, clamped 1..15).
  Classifies each issue of the tick (ENGAGED / QUEUED), then dispatches under that ceiling.

  ⚠ **CE N'EST PAS « at most ONE active workflow_run per repo », ET LE DEFAUT LIVRE LE DIT.** Le
  mecanisme est un COMPTEUR, pas un booleen (`Admission` : « Serial is this ceiling at 1, not
  another mechanism ») : sur un projet qui ne declare rien, CINQ workflow_runs peuvent voler
  ensemble. Ecrire ici « un seul » rend au lecteur un invariant de serialisation que le runtime
  n'a pas. Le nom du module garde « lease » parce que c'est le vocabulaire du corpus, mais l'objet
  est un plafond.

  **Le plafond est PER HUMAIN, et c'est le modele — pas une fuite du filtre.** Le compte se fait sur
  la liste obtenue avec `assigned_by=<mon humain>`, donc deux humains sur un depot tiennent deux
  budgets. Toute la fleet est per-humain (architect cape par uid, pods, feed, scoping) et une config
  centrale qui accorde un quota PAR UTILISATEUR est la forme ordinaire de la chose ; l'endroit ou la
  valeur est declaree ne dit rien de qui elle borne. `Admission.max_fan/0` porte le raisonnement.
  Ce qui borne le DEPOT est ailleurs : les sieges de pool par `(role, repo)`, et le fusible
  `Spawner.max_pods` en dernier ressort.

  ## The decision (business core)

    * **ENGAGED** = pod in flight (`lcars-in-flight`) OR engraved route advanced beyond the 1st
      step (workflow_run started, between two step_runs) → it HOLDS the lease; we
      dispatch its current step (continue), never a 2nd start.
    * **QUEUED** = routed at the 1st step, or routeless (to be onboarded) → only STARTS if
      the lease is free; otherwise waits for the next tick (serialization).
    * The lease reads on the ROUTE (append-only, robust), NEVER on the success of the
      workflow_map load: a TRANSIENTLY unreadable workflow_map cannot
      exclude an advanced workflow_run → **fail-closed** (classified ENGAGED, lease HELD).
      DURABLE absence → escalation (IncidentRegistry: 1st = note, recurrence = ONE issue
      then cooldown — the registry's escalation memory IS the throttle) — never a
      silently blocked repo.

  ## Lease vs tally — two concerns that the dispatch return mixes

  The canonical order of the spawn is lock → pod → enqueue → WAKE (the wake LAST):
  `{:error, {:wake_unreached, …}}` means the workflow_run IS started (lease TAKEN)
  but the anomaly is still counted in `errors` (surfaced via `last_tally_errors`/telemetry — an
  unreachable kick is never swallowed as a silent success; per-item errors do NOT feed the poller's
  `err_streak` backoff, which counts whole-tick failures only). Hence the internal return
  `{tally, started?}`: `started?` drives the lease INDEPENDENTLY of the error.

  ## Hardened boundary

  `Seams` (narrow struct, prod defaults resolved AT the construction SITE — same rule as
  `Reconciliation.Seams`): the cluster never reads the poller's state. The cross-tick
  state (2-tick grace of orphans, err_streak) stays at the GenServer.

  This module also owns the **tally** vocabulary (`zero_tally/0`, `merge_tally/2`)
  — the observability currency of the tick, produced here and aggregated by the poller.
  """

  alias Fleet.Forge.Payload
  alias Fleet.Pilot.Poller.Admission

  # workflow_run lock (single source `Fleet.Labels`) — fast-path `classify_issue`
  # (in-flight → ENGAGED without a route read).
  @in_flight Fleet.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Hardened boundary of the lease: the ONLY reads that `Lease` can do. The prod
    defaults (`Fleet.Workflow.Loader`, `IncidentRegistry.record_or_escalate/4`) are resolved
    by the poller AT the construction site — here, everything is already concrete.
    """
    @enforce_keys [:forge, :repo, :forge_opts, :workflow_map_loader, :incident_fun]
    defstruct [
      # Forge client (concrete module — the test override is resolved upstream).
      :forge,
      # Repo "owner/name" of the current iteration of the multi-project scan.
      :repo,
      # Forge opts (base_url, token…).
      :forge_opts,
      # workflow_map loader (module with .load!/1) — never nil here.
      :workflow_map_loader,
      # Escalation of an unreadable workflow_map (arity 4) — never nil here.
      :incident_fun,
      # The dispatcher, in the SAME hardened boundary as the rest: the lease's arithmetic (who
      # starts, who waits) is not testable against a module referenced by a literal. Defaulted,
      # so the prod construction site says nothing new.
      dispatcher: Fleet.Pilot.StepDispatcher
    ]

    @type t :: %__MODULE__{
            forge: module(),
            repo: String.t(),
            forge_opts: keyword(),
            workflow_map_loader: module(),
            dispatcher: module(),
            incident_fun: (String.t(), String.t(), term(), keyword() -> term())
          }
  end

  @typedoc "Counters of a tick: items dispatched / skipped / in error."
  @type tally :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc "Blank tally."
  @spec zero_tally() :: tally()
  def zero_tally, do: %{dispatched: 0, skipped: 0, errors: 0}

  @doc "Field-by-field tally sum."
  @spec merge_tally(tally(), tally()) :: tally()
  def merge_tally(a, b) do
    %{
      dispatched: a.dispatched + b.dispatched,
      skipped: a.skipped + b.skipped,
      errors: a.errors + b.errors
    }
  end

  @doc """
  Classifies and dispatches issues under the repository lease.
  """
  @spec process_issues([map()], MapSet.t(), keyword(), Seams.t()) :: tally()
  def process_issues(issues, pr_issue_ids, dispatch_opts, %Seams{} = seams) do
    # Coherence: the routing lives in SCOPED LABELS (`wfmap/*` + `stage/*`, engraved by `post_route`) —
    # a forge-side state-machine, not a comment. We read the route → dispatch (workflow_map_role). The
    # ceiling reads on the same route (a durable forge fact). We classify each issue ONCE:
    #   - ENGAGED (in-flight, or route advanced beyond the 1st step = workflow_run started) → holds the lease;
    #     we dispatch its current step (continues the step_run, or skips if in-flight).
    #   - QUEUED (routed at the 1st step, or routeless to be onboarded, not yet dispatched) → starts only
    #     if a seat is free under `max_fan`; otherwise waits (`wait/at_capacity`, next tick).
    # `classify_issue` reads the route (+ loads the workflow_map) ONCE and THREADS it to the dispatch via
    # `prefetch` (merged into the opts) → the lease classification and the dispatch read the SAME
    # data without a second get_route / workflow_map load.
    classified =
      issues
      |> Enum.map(fn issue ->
        pr? = MapSet.member?(pr_issue_ids, Map.get(issue, "number"))
        {engaged, prefetch} = classify_issue(issue, pr?, seams)
        {issue, pr?, engaged, prefetch}
      end)
      |> Enum.sort_by(fn {issue, _pr?, _engaged, _pf} -> Map.get(issue, "number") end)

    # THE CEILING — `max_fan`: how many workflow_runs this human may hold in flight on this repo. A
    # boolean would be the same parameter at a coarser resolution (**serial IS this ceiling at 1**),
    # and it could only say "one" or "as many as there are" — the second being genuinely unbounded:
    # a repo with forty queued tickets starts forty runs.
    #
    # A repo holds several runs without the operator flipping anything, which is why the default
    # ceiling is LOW (5). PER REPO (and per human), not per container: the count is per repo, and a fleet-wide knob
    # would make serializing one project to watch its pipeline end to end serialize every other
    # project too. `dispatch_opts` carries the `:code_root` seam tests inject.
    max_fan = Admission.max_fan(seams.repo, dispatch_opts)

    # IN-FLIGHT crosses BOTH dispatch rails. Counting only what this rail can see — the ENGAGED
    # issues — misses a ticket in its jury phase: it has left the issues side (it is dispatched
    # through the pulls) and counts for nothing. Consequence, measured and not theoretical: a repo
    # serialized to one workflow_run starts a SECOND one as soon as the first reaches its jury. The
    # hole is open in serial too; the fan-out only makes it visible.
    #
    # The two halves are side by side: `pr_issue_ids` is passed in and already computes
    # `pr?` below. They are DISJOINT by construction, not by luck — `classify_issue/3` answers
    # `engaged = false` for every PR-bearing ticket, first clause, no other path. So this is a sum,
    # never a union to deduplicate.
    #
    # ⚖ A ticket PARKED under `lcars-awaits-arch` is classified like any other (2026-09-05): the
    # label is not read here, the ROUTE is. Parked with an ADVANCED route, it holds its seat — its
    # run exists and resumes when the human acts, and a second run started meanwhile would put two
    # in flight on a serial project when it wakes. Parked at the ROOT (a brief the scoper refused),
    # it has no advanced run, holds no seat, and competes for one again once unparked — the next
    # ticket starts. `StepDispatcher.decide/1` is what refuses the parked ticket's own dispatch.
    in_flight =
      Enum.count(classified, fn {_issue, _pr?, engaged, _pf} -> engaged end) +
        MapSet.size(pr_issue_ids)

    # ADMISSION ORDER — ascending ticket number, decided HERE and not inherited.
    #
    # The listing carries no `sort`: whatever order the forge returns is the order the seats were
    # handed out in, which under Gitea means "most recently touched first". So the ticket that got
    # the last seat was the one someone had just commented on — a rule nobody wrote, that changes
    # when a human types, and that reverses if the forge changes its default.
    #
    # Ascending id is the one order a queue can be READ in: it is the arrival order, it is stable
    # across ticks (so a refused ticket keeps its place instead of drifting), and it needs no field
    # the forge might not have. It is a property of the ADMISSION, not of the transport — which is
    # why it lives here and not as a query parameter that only the HTTP path would obey.
    #
    # The accumulator is the COUNT, seeded with what is already flying. An ENGAGED step and a jury
    # ticket do not increment it — they are already inside `in_flight`; only a fresh START does.
    {tally, _fan} =
      Enum.reduce(classified, {zero_tally(), in_flight}, fn
        {issue, pr?, engaged, prefetch}, {acc, fan} ->
          payload = wrap_issue_as_payload(issue, seams.repo)
          item_opts = Keyword.merge(dispatch_opts, prefetch)
          wait = Admission.current_wait(payload)

          cond do
            # Issue with an open fleet PR → JUDGE phase (dispatched via the pulls). SKIP on the
            # issue side (otherwise producer re-spawn). It already counts in `in_flight`.
            pr? ->
              {acc2, _} = Admission.refuse(:pr_open, item_opts, issue["number"], wait, acc)
              {acc2, fan}

            # ENGAGED pipeline → dispatches its current step. Already counted: continuing a run is
            # not entering one, and a ceiling that charged for both would strangle a project at its
            # second step rather than at its second ticket.
            engaged ->
              {acc2, _started?} =
                step_do_dispatch(payload, item_opts, acc, seams.dispatcher)

              {acc2, fan}

            # The project is FULL → the ticket waits, and it SAYS so. Silent, this branch makes a
            # held-back ticket indistinguishable from a forgotten one, tick after tick.
            fan >= max_fan ->
              {acc2, _} = Admission.refuse(:at_capacity, item_opts, issue["number"], wait, acc)
              {acc2, fan}

            # QUEUED with room → STARTS, unless a PRECONDITION is not met, and takes a seat only if
            # it actually started.
            #
            # LA DÉPENDANCE EST LUE À L'ENTRÉE, PAS SEULEMENT SUBIE À LA SORTIE. La forge applique
            # déjà les dépendances d'issues : elle refuse la FERMETURE d'un ticket dont un bloqueur
            # est ouvert. Sans cette lecture-ci, la fleet dispatche quand même — le producteur
            # travaille, livre, et le mur ne se révèle qu'au merge : deux rails parallèles qui ne
            # se rencontrent qu'au moment le plus cher, exactement l'état du CI avant sa porte.
            # La contrainte porte sur le DÉMARRAGE, jamais sur la poursuite : un run ENGAGÉ est
            # déjà passé au-dessus (clause précédente), et l'interrompre en vol le coincerait.
            true ->
              dispatch_unless_blocked(
                open_blockers(issue, seams),
                {payload, item_opts, issue["number"], wait},
                {acc, fan},
                seams
              )
          end
      end)

    tally
  end

  # Les bloqueurs ENCORE OUVERTS de ce ticket. Un bloqueur fermé compte comme satisfait — c'est la
  # sémantique de la forge, et on ne la ré-invente pas ici.
  #
  # Lecture PARESSEUSE, dans la dernière branche seulement : un ticket déjà en vol, porteur de PR ou
  # refusé au plafond n'a pas besoin qu'on interroge la forge sur ses arêtes. Le coût est donc UN
  # GET par ticket réellement candidat au démarrage, pas par ticket vu.
  #
  # ⚠ FORGE MUETTE ≠ AUCUN BLOQUEUR. L'argument contraire — « la forge REFUSERA la fermeture si un
  # bloqueur est ouvert, donc le mur tient de toute façon » — est exactement celui que cette lecture
  # existe pour rejeter : sans elle, le producteur travaille, livre, et le mur ne se révèle qu'au
  # merge. Deux rails parallèles qui ne se rencontrent qu'au moment le plus cher.
  #
  # ⚠ ET REFUSER N'EST PAS BLOQUER : bloquer la FLEET sur un hoquet réseau serait pire, mais on
  # marque CE ticket en attente et on passe au suivant. Le tick d'après relit ; rien d'autre ne
  # s'arrête.
  #
  # Du côté du ticket, une porte illisible et une porte fermée sont le MÊME fait — il est arrêté là,
  # personne ne travaille dessus. La distinction vit dans la RAISON du skip, où elle est actionnable.
  # LA PLACE N'EST PRISE QUE SI LE RUN A REELLEMENT DEMARRE : `started?` faux laisse `fan` intact,
  # sans quoi un refus en aval consommerait un siege que personne n'occupe.
  #
  # ⚠ « BLOQUEUR ILLISIBLE » N'EST PAS « AUCUN BLOQUEUR ». Les deux refusent, avec deux raisons
  # distinctes — un depend non lu qui dispatcherait quand meme rendrait cette lecture decorative.
  defp dispatch_unless_blocked({:ok, []}, {payload, item_opts, _n, _wait}, {acc, fan}, seams) do
    {acc2, started?} = step_do_dispatch(payload, item_opts, acc, seams.dispatcher)
    {acc2, if(started?, do: fan + 1, else: fan)}
  end

  defp dispatch_unless_blocked({:ok, [blocker | _]}, {_p, item_opts, n, wait}, {acc, fan}, _seams) do
    {acc2, _} = Admission.refuse({:depends, blocker}, item_opts, n, wait, acc)
    {acc2, fan}
  end

  defp dispatch_unless_blocked({:error, why}, {_p, item_opts, n, wait}, {acc, fan}, _seams) do
    {acc2, _} = Admission.refuse({:depends_unreadable, why}, item_opts, n, wait, acc)
    {acc2, fan}
  end

  defp open_blockers(issue, %Seams{} = seams) do
    case seams.forge.issue_dependencies(seams.repo, Map.get(issue, "number"), seams.forge_opts) do
      {:ok, deps} when is_list(deps) ->
        {:ok,
         deps
         |> Enum.filter(&(Map.get(&1, "state") == "open"))
         |> Enum.map(&Map.get(&1, "number"))
         |> Enum.reject(&is_nil/1)}

      other ->
        {:error, other}
    end
  end

  # ⚠ DEUX PREOCCUPATIONS DISTINCTES, QUE LE RETOUR DU DISPATCH MELANGE :
  #
  #   * LE BAIL — le run a-t-il DEMARRE ? L'ordre canonique du spawn place le REVEIL en DERNIER,
  #     donc un reveil rate signifie que le run EST demarre : verrou, pod et brief sont en place. Il
  #     tient donc le bail — sinon une 2e issue du meme depot, dans le meme tick, lancerait un 2e
  #     run, et deux branches concurrentes finissent en conflit de merge.
  #   * LE COMPTE — y a-t-il une anomalie a FAIRE REMONTER ? Le reveil manque est compte comme
  #     erreur : un kick injoignable ne doit PAS etre avale comme un succes silencieux, le pod ne
  #     tournant pas tant qu'il n'est pas reveille.
  #
  # D'ou un troisieme cas : DEMARRE pour le bail, ANOMALIE pour le compte. C'est « un pod a-t-il ete
  # mis en vol » qui pilote la prise du bail, INDEPENDAMMENT du fait que le dispatch se soit termine
  # sans erreur.
  defp step_do_dispatch(payload, opts, acc, dispatcher) do
    Admission.admit(
      fn -> dispatcher.dispatch_issue(payload, opts) end,
      opts,
      payload["number"],
      Admission.current_wait(payload),
      acc
    )
  end

  # Classifies an issue (lease) AND pre-resolves what `dispatch_issue` would otherwise re-read. Returns
  # `{engaged?, prefetch_kw}`; `prefetch_kw` (merged into the dispatch opts) carries `:prefetched_route` +
  # `:prefetched_workflow_map` → forge/disk read ONCE only. ENGAGED = pod in flight (`in-flight`) OR route
  # advanced beyond the 1st step (workflow_run started, between two step_runs). Fast-path: in-flight → no route
  # read (`decide` skips it anyway). Routeless (`:none`) → QUEUED, nil route threaded (onboard
  # downstream). get_route error (or unexpected shape) → fail-CLOSED: ENGAGED (lease HELD), nothing threaded
  # (the dispatch re-reads → fail-loud `:route_resolution`); the lease is NOT released for a maybe-advanced
  # workflow_run — symmetric with the transient workflow_map-load failure below.
  defp classify_issue(_issue, true = _pr?, _seams), do: {false, []}

  defp classify_issue(issue, false = _pr?, seams) do
    labels = Payload.label_names(issue)

    if @in_flight in labels do
      {true, []}
    else
      # Route DERIVED from the labels already in hand (BL-6-40 Phase 2): `list_open_issues` returns
      # them with the issue, and `get_route` would redo a GET per issue per tick for the same data.
      # The number is not read here at all — it only ever serves to ADDRESS a request.
      #
      # `get_route`'s `{:error, _}` branch has no meaning for THIS caller, and that is worth naming:
      # it exists only because there is a network call. With no call, there is no transient failure
      # to cover; the fail-closed it carries stays whole for the callers of `get_route/3`, which do
      # still read.
      case seams.forge.route_from_labels(Payload.labels(issue)) do
        {:ok, {workflow_map_name, step} = route}
        when is_binary(workflow_map_name) and is_binary(step) ->
          # The lease reads on the ROUTE (append-only, robust), NEVER on the success of the load of the workflow_map. A
          # PRESENT route = a workflow_run already entered into the machine. ENGAGED iff the current step is not the 1st
          # of the workflow_map (workflow_run advanced between two step_runs). If the workflow_map fails to load
          # TRANSIENTLY (network/forge nil), we CANNOT exclude that this workflow_run is advanced → fail-closed: we
          # classify it ENGAGED (lease HELD). Otherwise a nil-workflow_map would lose the lease of an engaged
          # workflow_run → a 2nd issue of the same repo would start a 2nd workflow_run (loss of serialization). The
          # dispatch of ITS step fails-loud if the workflow_map is missing (workflow_map re-read on the StepDispatcher
          # side), but the lease does NOT release for all that. WorkflowMap back at the next tick → precise
          # classification resumed.
          workflow_map = load_workflow_map_or_nil(workflow_map_name, seams)
          engaged = is_nil(workflow_map) or not first_step?(workflow_map, step)
          {engaged, [prefetched_route: route, prefetched_workflow_map: workflow_map]}

        :none ->
          {false, [prefetched_route: nil]}

        _ ->
          # Fail-CLOSED (symmetric with the workflow_map-load-failure branch above): a transient get_route
          # error — or any unexpected shape — leaves engagement UNKNOWN. Releasing the lease here would let
          # a maybe-advanced workflow_run lose its serialization → a 2nd issue of the same repo would start a
          # 2nd workflow_run (the exact danger the sibling guards, 6 lines up). So classify ENGAGED (lease
          # HELD), nothing prefetched; the dispatch re-reads (fail-loud `:route_resolution`) and precise
          # classification resumes at the next tick.
          {true, []}
      end
    end
  end

  # Loads the workflow_map; `nil` on failure (the dispatch will retry → fail-loud).
  defp load_workflow_map_or_nil(workflow_map_name, seams) do
    # The rescue lives in the single authority (WorkflowMapNav.safe_load); THIS site keeps its
    # own semantics (nil = fail-closed lease + G6 escalation below).
    case Fleet.Pilot.WorkflowMapNav.safe_load(
           seams.workflow_map_loader,
           workflow_map_name,
           Fleet.Workflow.Loader.card_opts_for_repo(seams.repo)
         ) do
      {:ok, map} ->
        map

      {:error, {:workflow_map_load_failed, _name, message}} ->
        # G6: the workflow_map does NOT load (removed/renamed from the catalog, or broken schema). The lease
        # stays fail-closed (cf. classify_issue: we do not release the lease of a maybe-advanced
        # workflow_run) — BUT if the absence is DURABLE, the issue holds the lease and the repo is blocked
        # FOREVER silently (Jupiter: nobody will see it). We ESCALATE: IncidentRegistry keyed
        # by signature → 1st occurrence = WAL note, RECURRENCE (map missing at every tick) = ONE
        # sysadmin issue, then the registry's escalation COOLDOWN suppresses the per-tick repeats
        # (the dedup alone is NOT a throttle: it escalates on EVERY recurrence — one issue per
        # tick on a durable failure, ~2 880/day). The escalation must never break the
        # tick (rescue in escalate_workflow_map_incident, silent at this site); the load failure
        # recurs at EVERY tick while the map stays broken, so a skipped escalation is re-attempted
        # one tick later — and the registry itself logs error when its owner is unavailable.
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
    # The escalation itself must NEVER take down the tick (registry down, etc.).
    _ -> :escalation_skipped
  end

  # Is the step the 1st of the workflow_map (= routed but not advanced = QUEUED)? workflow_map anomaly → `true` (treated
  # as "not engaged": the dispatch fail-loud will surface it, never a lease wedge by an unreadable workflow_map).
  defp first_step?(workflow_map, step) do
    case Fleet.Pilot.WorkflowMapNav.first_step(workflow_map) do
      {:ok, {first, _role}} -> step == first
      _ -> true
    end
  end

  # Shapes the payload expected by `StepDispatcher.dispatch_issue` (the issue + its origin repo).
  defp wrap_issue_as_payload(issue, repo) do
    %{
      "issue" => issue,
      "repository" => %{"full_name" => repo}
    }
  end
end
