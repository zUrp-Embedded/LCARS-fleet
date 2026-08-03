defmodule Fleet.Pilot.Poller.Lease do
  @moduledoc """
  Repo-serialized lease of the step rail: **at most ONE
  active workflow_run per repo**. Classifies each issue of the tick (ENGAGED / QUEUED), then
  dispatches under this lease — the feature-branches stay sequential → clean rebase merge (linear history; FF is NOT guaranteed, `main` advances under parallel PRs — cf. `ForgeClient.merge_pr` `Do: rebase`).

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

  **Last revised**: 2026-08-03
  """

  require Logger

  alias Fleet.Pilot.StepDispatcher

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

  @typedoc "Counters of a tick: items dispatched / skipped / in error."
  @type tally :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc "Blank tally (single source). The error paths use `%{zero_tally() | errors: 1}`."
  @spec zero_tally() :: tally()
  def zero_tally, do: %{dispatched: 0, skipped: 0, errors: 0}

  @doc "Field-by-field sum of two tallies (issues+pulls aggregation, cross-repo)."
  @spec merge_tally(tally(), tally()) :: tally()
  def merge_tally(a, b) do
    %{
      dispatched: a.dispatched + b.dispatched,
      skipped: a.skipped + b.skipped,
      errors: a.errors + b.errors
    }
  end

  @doc """
  Classifies then dispatches the issues of the tick under the repo-serialized lease. `pr_issue_ids` =
  issues carrying an open fleet PR (JUDGE phase, dispatched via the pulls → SKIP on the issue
  side, the PR holds the lease). `dispatch_opts` = opts for `StepDispatcher.dispatch_issue`
  (prepared once per tick by the poller). Yields the tally of the issues path.
  """
  @spec process_issues([map()], MapSet.t(), keyword(), Seams.t()) :: tally()
  def process_issues(issues, pr_issue_ids, dispatch_opts, %Seams{} = seams) do
    # Coherence: the routing lives in SCOPED LABELS (`wfmap/*` + `stage/*`, engraved by `post_route`) —
    # a forge-side state-machine, not a comment. We read the route → dispatch (workflow_map_role). The
    # lease "1 active workflow_run/repo" also reads on the same route (a durable forge fact). We classify each issue ONCE:
    #   - ENGAGED (in-flight, or route advanced beyond the 1st step = workflow_run started) → holds the lease;
    #     we dispatch its current step (continues the step_run, or skips if in-flight).
    #   - QUEUED (routed at the 1st step, or routeless to be onboarded, not yet dispatched) → starts only
    #     if the lease is free; otherwise waits (serialization → sequential feature-branches → rebase merge, cf. `ForgeClient.merge_pr`).
    # `classify_issue` reads the route (+ loads the workflow_map) ONCE and THREADS it to the dispatch via
    # `prefetch` (merged into the opts) → the lease classification and the dispatch read the SAME
    # data without a second get_route / workflow_map load.
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
            # Issue with an open fleet PR → JUDGE phase (dispatched via the pulls). SKIP on the
            # issue side (otherwise producer re-spawn). The PR holds the lease.
            pr? ->
              {%{acc | skipped: acc.skipped + 1}, lease}

            # ENGAGED pipeline → dispatches its current step; it HOLDS the lease → lease unchanged.
            engaged ->
              dispatch_engaged(payload, item_opts, acc, lease)

            # QUEUED, lease held by another workflow_run → waits.
            lease ->
              {%{acc | skipped: acc.skipped + 1}, lease}

            # QUEUED, lease free → STARTS (takes the lease if effectively dispatched).
            true ->
              start_workflow_run(payload, item_opts, acc)
          end
      end)

    tally
  end

  # Dispatch of an item + update of the tally AND the lease. Two DISTINCT concerns, that the return of
  # `dispatch_issue` mixes:
  #
  #   * LEASE — did the workflow_run START (pod spawned + `lcars-in-flight` lock placed)? The canonical order
  #     of the spawn (`StepDispatcher.spawn_step`) is lock → pod → enqueue → WAKE, the wake LAST. So
  #     `{:error, {:wake_unreached, …}}` means: the workflow_run IS started (lock + pod + brief in place),
  #     ONLY the tmux wake failed. The workflow_run therefore holds the repo-serialized lease — otherwise a 2nd issue of the same
  #     repo in the same tick would start a 2nd workflow_run (two concurrent feature-branches → merge conflict).
  #   * TALLY/telemetry — is there an anomaly to SURFACE? The missed wake is still counted in `errors` (it
  #     surfaces via `last_tally_errors`/telemetry, NOT the `err_streak` backoff — per-item dispatch errors
  #     do not feed it, only whole-tick failures do): an unreachable kick must NOT be swallowed as a silent
  #     success (the pod does not run until it is woken).
  #
  # Hence the 3rd case `wake_unreached` = (started for the LEASE, anomaly for the TALLY). We return
  # `{tally, started?}`; `started?` (= a pod was actually put in flight this tick) drives the lease taking,
  # INDEPENDENTLY of whether the dispatch finished without error.
  defp step_do_dispatch(payload, opts, acc) do
    case StepDispatcher.dispatch_issue(payload, opts) do
      {:ok, {:spawned, _pod_id, _role}} ->
        {%{acc | dispatched: acc.dispatched + 1}, true}

      # workflow_run STARTED (lock + pod + brief placed) but wake unreachable. The lease is TAKEN (started?
      # = true); the anomaly is still counted in `errors` (surfaced via `last_tally_errors`/telemetry,
      # never swallowed — it does NOT feed the `err_streak` backoff).
      {:error, {:wake_unreached, _pod_id, _role, _reason}} ->
        {%{acc | errors: acc.errors + 1}, true}

      {:skipped, _reason} ->
        {%{acc | skipped: acc.skipped + 1}, false}

      # Real dispatch failure (nothing started — the compensation removed the lock + killed the fresh pod) → lease FREE.
      {:error, _reason} ->
        {%{acc | errors: acc.errors + 1}, false}
    end
  end

  # Dispatch of an ENGAGED workflow_run (it ALREADY holds the lease): the lease stays unchanged whatever happens
  # (the tally is updated, `started?` is ignored — the engagement comes from the classification, not from this step_run).
  defp dispatch_engaged(payload, opts, acc, lease) do
    {acc2, _started?} = step_do_dispatch(payload, opts, acc)
    {acc2, lease}
  end

  # Start of a QUEUED workflow_run (free lease): dispatch; if a pod was actually put in flight
  # (spawned OR wake_unreached = lock+pod placed), the lease becomes HELD → the other queued issues of the same
  # tick wait (serialization 1 workflow_run/repo). A missed wake holds the lease (the workflow_run is started),
  # NOT a dispatch failure (nothing started).
  defp start_workflow_run(payload, opts, acc) do
    {acc2, started?} = step_do_dispatch(payload, opts, acc)
    {acc2, started?}
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
    labels = Enum.map(Map.get(issue, "labels") || [], & &1["name"])

    if @in_flight in labels do
      {true, []}
    else
      # Route DERIVEE des labels deja en main (BL-6-40 Phase 2) : `list_open_issues` les rend avec
      # l'issue, et `get_route` refaisait un GET par issue et par tick pour la meme donnee. Le
      # numero n'est meme plus lu ici — il ne servait qu'a ADRESSER la requete.
      #
      # La branche `{:error, _}` de `get_route` disparait pour CET appelant, et c'est une
      # consequence a nommer : elle n'existait que parce qu'il y avait un appel reseau. Sans appel,
      # pas de panne transitoire a couvrir ; le fail-closed qu'elle portait reste entier pour les
      # appelants de `get_route/3`, qui, eux, lisent encore.
      case seams.forge.route_from_labels(Map.get(issue, "labels") || []) do
        {:ok, {workflow_map_name, step} = route}
        when is_binary(workflow_map_name) and is_binary(step) ->
          # The lease reads on the ROUTE (append-only, robust), NEVER on the success of the load of the
          # workflow_map. A PRESENT route = a workflow_run already entered into the machine. ENGAGED iff the current step
          # is not the 1st of the workflow_map (workflow_run advanced between two step_runs). If the workflow_map fails to load
          # TRANSIENTLY (network/forge nil), we CANNOT exclude that this workflow_run is advanced → fail-closed:
          # we classify it ENGAGED (lease HELD). Otherwise a nil-workflow_map would lose the lease of an engaged workflow_run →
          # a 2nd issue of the same repo would start a 2nd workflow_run (loss of serialization). The dispatch of ITS
          # step fails-loud if the workflow_map is missing (workflow_map re-read on the StepDispatcher side), but the lease does NOT release
          # for all that. WorkflowMap back at the next tick → precise classification resumed.
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
    case Fleet.Pilot.WorkflowMapNav.safe_load(seams.workflow_map_loader, workflow_map_name) do
      {:ok, map} ->
        map

      {:error, {:workflow_map_load_failed, _name, message}} ->
        # G6: the workflow_map does NOT load (removed/renamed from the catalog, or broken schema). The lease
        # stays fail-closed (cf. classify_issue: we do not release the lease of a maybe-advanced
        # workflow_run) — BUT if the absence is DURABLE, the issue holds the lease and the repo is blocked
        # FOREVER silently (Jupiter: nobody will see it). We ESCALATE: IncidentRegistry keyed
        # by signature → 1st occurrence = WAL note, RECURRENCE (map missing at every tick) = ONE
        # sysadmin issue, then the registry's escalation COOLDOWN suppresses the per-tick repeats
        # (the dedup alone was NOT a throttle: it escalated on EVERY recurrence — one issue per
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

  # Is the step the 1st of the workflow_map (= routed but not advanced = QUEUED)? workflow_map anomaly → `true`
  # (treated as "not engaged": the dispatch fail-loud will surface it, never a lease wedge by an unreadable workflow_map).
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
