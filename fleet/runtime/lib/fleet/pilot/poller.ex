defmodule Fleet.Pilot.Poller do
  @moduledoc """
  Reactor of the forge-state-machine rail (**STEP mode only**), **multi-project**: at each
  tick it DISCOVERS the fleet-org repos via `list_org_repos` (WS3: every repo of the fleet org IS a
  fleet project), then delegates the open issues + PRs to role spawning via `StepDispatcher`.

  ## Role

  The forge IS the state machine; this poller is its reactor. At each tick, for EVERY repo
  of the fleet org, it lists the open **issues** + **PRs** and delegates:

    * **assigned issue** (assignee=human owner), unlocked, without an open PR → spawn the
      **producer** role (`StepDispatcher.dispatch_issue`; role = `:producer_role`, default engineer).
    * **PR** with a requested reviewer → spawn the **judge**; PR `REQUEST_CHANGES` without a reviewer → re-spawn
      the **producer** for the rework (`StepDispatcher.dispatch_review`).
    * `lcars-in-flight` lock → skip (a pod is already working the brick). **Repo-serialized lease**:
      at most one active workflow_run per repo (sequential feature-branches → clean rebase merge, linear history; FF NOT guaranteed — cf. `ForgeClient.merge_pr`).

  ## Robustness (port from v1.5 `LcarsFleetPoller`, retained)

    * **Jitter ±10%** on the interval — anti thundering-herd (N daemons that restart together).
    * **Exponential backoff** on API errors (capped at 5 min) — a forge that is down does not flood the logs.
    * **`try/rescue` safety-net** on `do_poll/1` — a bug in the dispatch path does not crash the poller.
    * **Telemetry** `[:fleet_pilot, :poller, :poll]` (duration_ms, dispatched, skipped, errors).

  ## Sub-modules

    * `Backoff` — PURE computation of the delay (jitter + exponential backoff); the GenServer keeps
      the effect (`schedule/1`) and the rescue (`safe_poll`).
    * `Lease` — repo-serialized lease (ENGAGED/QUEUED classification + dispatch under lease,
      issues path); hardened boundary `Lease.Seams`, tally vocabulary.
    * `Reconciliation` — reclaiming of orphaned `lcars-in-flight` locks (the 2-tick
      grace — cross-tick state — stays HERE, `orphan_lock_suspects`).

  Stay HERE: the loop (org-repo discovery + admission + tally orchestration + state
  backoff), the pulls path (`step_process_pulls`, not guarded by the lease) and the throttled
  awaits-arch re-kick (coupled to `poll_count`).

  ## Init configuration

    * (Plus d'opt `:repo` à l'init : le champ struct `repo` reste comme porteur d'itération —
      posé par `do_poll` à chaque repo découvert — mais n'est plus un seam d'entrée. La découverte
      par org-membership est la seule source de repos.)
    * `:human` — test seam; default `Fleet.Credentials.Human.current!()` (fail-loud), the
      REAL required source of multi-user scoping.
    * `:interval_ms` — default `30_000` (30s).
    * `:forge_opts` — ForgeClient keyword (base_url, token, req_options).
    * test seams: `:forge_client`, `:loader`, `:workflow_map_loader`, `:spawner` (injected if non-nil).
    * `:start_tick?` — default `true`; `false` = no auto first tick (tests drive via `force_poll/1`).

  ## History — legacy mode REMOVED (2026-06-16)

  The old legacy `do_poll` mode (route-table → `Dispatcher.dispatch` → `Fleet.Workflow.start_pipeline`
  = RAM Executor, via the `AutoDispatcher` state) was **removed** together with the legacy rail
  (`auto_dispatcher`/`dispatcher`/`pipeline_invoker`). The `Routing` module itself was removed
  as dead code. Only step mode remains; the RAM engine falls downstream.
  """

  use GenServer
  require Logger

  alias Fleet.Pilot.Opts
  alias Fleet.Pilot.Poller.Reconciliation
  alias Fleet.Pilot.StepDispatcher

  # PURE tick timing (anti-herd jitter + capped exponential backoff) — the GenServer keeps
  # the EFFECT (`schedule/1` = Process.send_after) and the rescue (`safe_poll`), Backoff yields the delay.
  alias Fleet.Pilot.Poller.Backoff

  # Repo-serialized lease (ENGAGED/QUEUED classification + dispatch under lease) — the business CORE of
  # the issues path, extracted. Hardened boundary: reads a narrow `Lease.Seams` (`lease_seams/1`), prod
  # defaults resolved HERE. Also owns the tally vocabulary (`zero_tally/merge_tally`).
  alias Fleet.Pilot.Poller.Lease

  # HUMAN lock placed on the ISSUE at escalation (gatekeeper verdict escalate/halt/redirect, or unresolved
  # conflict). The poller computes the SET of issues carrying it (already listed at the tick → zero I/O) and threads
  # it to the pulls → `dispatch_review` skips the judge of a PR whose parent issue awaits the arch.
  @awaits_arch Fleet.Pilot.Labels.awaits_arch()

  @default_interval_ms 30_000

  # G4 — cadence for RE-KICKING the arch as long as at least one issue is waiting (`lcars-awaits-arch`). Throttled:
  # 1 wake every N ticks (at ~30s/tick, N=10 = ~5 min). A wake can cost a claude TURN → un-throttled,
  # it would be a 30s churn (unbounded spend, anti-Jupiter). Frequent enough that a lost wake does not block
  # an issue FOREVER, rare enough not to hammer the human airlock.
  @awaits_rekick_every 10

  # Fenêtre de coalescence du kick webhook (Z6e) : une rafale d'events dans la fenêtre = UN poll.
  @gitea_kick_debounce_ms 1_000

  defstruct [
    :repo,
    :interval_ms,
    # The human of THIS fleet (OS user, `Human.current!()`). Multi-user scoping: we dispatch
    # ONLY its issues (otherwise Alice's poller spawns for Bob). Test seam: opt `:human`.
    :my_human,
    # The forge org = THE admission frontier (WS3): the poller discovers via `list_org_repos(org)`, every repo
    # of the org IS a fleet project. Default `fleet` (config `:fleet_pilot, :fleet_org`); MUST match the org of
    # create_project (`:fleet_mcp, :delegation_org`) — both default to `fleet`. Test seam: opt `:org`.
    :org,
    :forge_client_override,
    forge_opts: [],
    loader: nil,
    workflow_map_loader: nil,
    spawner: nil,
    task_queue: nil,
    # Wake recovery seam threaded down to `StepDispatcher.dispatch_issue` (default nil → the real
    # `WakeRecovery.wake/3`). Makes the contract "missed wake ⇒ workflow_run started, lease TAKEN" testable without hitting
    # the real IncidentRegistry/tmux.
    wake_recovery: nil,
    # G6 seam: escalation of an unreadable workflow_map (default nil → `IncidentRegistry.record_or_escalate/4`).
    # Makes "durably missing map ⇒ sysadmin escalation" testable without hitting the real registry/forge.
    incident_fun: nil,
    # Z6e (D-13, 2026-07-13) — coalescence du kick webhook : true = un poll accéléré est
    # déjà programmé, les events gitea.* suivants de la rafale ne re-programment RIEN.
    gitea_kick_pending?: false,
    poll_count: 0,
    error_count: 0,
    err_streak: 0,
    last_error: nil,
    # nb of DISPATCH errors (per item) of the last tick. The forge list
    # (`list_open_*`) can succeed while some `dispatch_*` fail — these errors are surfaced
    # here for observability (`stats/1`) + telemetry; they do NOT feed `err_streak` (the
    # multi-project `do_poll` resets the streak to 0 each successful tick, keeping only
    # `orphan_lock_suspects`) → they do not trigger backoff.
    last_tally_errors: 0,
    # Lock reconciliation: refs `{:issue|:pr, n}` seen ORPHANED (`lcars-in-flight` lock
    # without a live pod) at the previous tick. 2-tick grace (same grace as the PodWarden) → we only reclaim on the 2nd
    # consecutive tick (avoids unlocking a freshly dispatched pod or one in the process of dying).
    orphan_lock_suspects: MapSet.new()
  ]

  @type t :: %__MODULE__{
          repo: String.t(),
          interval_ms: pos_integer(),
          forge_client_override: module() | nil,
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

  @doc "Force an immediate (synchronous) poll. Used by tests + ops."
  @spec force_poll(GenServer.server()) :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }
  def force_poll(server \\ __MODULE__), do: GenServer.call(server, :force_poll, 30_000)

  @doc "Runtime stats: poll_count, error_count, err_streak, last_error, last_tally_errors."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(opts) do
    # Multi-project: no more mandatory `:repo` — the poller DISCOVERS its projects by ORG-MEMBERSHIP
    # (`list_org_repos(org)`, WS3: every repo of the fleet org IS a fleet project). `:repo` stays accepted
    # (tests/legacy/seam) but is no longer the source (do_poll overwrites it per iteration). `my_human` = the REAL
    # required source of SCOPING (`Human.current!()` fail-loud — a poller that does not know WHO it is cannot
    # scope its issues via `assigned_by`).
    state = %__MODULE__{
      my_human: Keyword.get(opts, :human) || Fleet.Credentials.Human.current!(),
      org: Keyword.get(opts, :org) || Application.get_env(:fleet_pilot, :fleet_org, "fleet"),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      forge_client_override: Keyword.get(opts, :forge_client),
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

    # Z6e (D-13) — le webhook gitea.* redevient UTILE : accélérateur de latence du poll
    # (le rail était MORT pour le dispatch depuis le retrait de l'AutoDispatcher 2026-06-16,
    # il n'alimentait plus que l'observation). Doctrine INCHANGÉE : le poll reste LA vérité
    # (forge-state-machine) — l'event est un HINT, jamais une donnée (payload ignoré).
    # Opt-in (défaut false = hermétisme test : pas de subscribe Bus parasite en async) ;
    # câblé true par Application.step_children! (prod).
    _ =
      if Keyword.get(opts, :subscribe_gitea, false) do
        :ok = Fleet.EventRouter.Bus.subscribe()
      end

    Logger.info(
      "Poller: start mode=step MULTI-PROJECT org=#{state.org} human=#{state.my_human} " <>
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

  # Z6e — hint webhook : un event gitea.* = « la forge a bougé » → poll accéléré via un
  # message DÉDIÉ :gitea_kick (⚠ PAS :poll — son handler re-programme le tick suivant :
  # injecter :poll créerait une CHAÎNE PARALLÈLE permanente ; :gitea_kick polle sans
  # toucher la chaîne). Coalescence 1s : une rafale de N webhooks = 1 poll.
  def handle_info(%Fleet.Event{type: type}, %__MODULE__{} = state) do
    if gitea_event?(type) and not state.gitea_kick_pending? do
      _ = Process.send_after(self(), :gitea_kick, @gitea_kick_debounce_ms)
      {:noreply, %{state | gitea_kick_pending?: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:gitea_kick, state) do
    {_result, new_state} = safe_poll(%{state | gitea_kick_pending?: false})
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp gitea_event?(type) when is_atom(type),
    do: String.starts_with?(Atom.to_string(type), "gitea.")

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

  # Returns `{result, new_state}` — rescue-wrapped. Shared by the tick (which throws away the
  # result) AND force_poll (which returns it) → force_poll does not bypass the rescue.
  defp safe_poll(state) do
    do_poll(state)
  rescue
    exception -> poll_crash(state, exception, "crash")
  catch
    kind, reason -> poll_crash(state, {kind, reason}, "exit/throw")
  end

  # rescue AND catch :exit/:throw — a `GenServer.call` to a dead dep (enqueue→TaskQueue,
  # spawn→Spawner) raises `:exit`, NOT `{:error}`; without the catch, the loop crashed (≠ the "state preserved"
  # that is announced). We degrade gracefully (err_streak + backoff, state preserved), like
  # `Reconciliation.live_owned_refs` (a `GenServer.call` can always `:exit` if the target dies — never
  # let it bubble up bare).
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

  # STEP mode only (the legacy `do_poll`/RAM Executor was removed). The scan is in
  # `step_do_poll/1`; this wrapper keeps the single entry point (shared jitter/backoff/safety-net).
  # Forge-driven discovery. The poller scans ALL the repos of the fleet org (`list_org_repos`,
  # WS3: every repo of the org IS a fleet project), not a hard-coded `:repo`. Per-repo: the step logic
  # UNCHANGED (state.repo set per iteration). Discovery OK → forge up → err_streak reset; the issue
  # scoping `assigned_by=my_human` stays the anti-theft guard even if one of Alice's repos leaked.
  # Discovery KO → backoff (handle_poll_error). The repo-serialized lease stays per-repo (concurrent across,
  # sequential within).
  #
  # Per-repo state: the per-item DISPATCH errors live in the TALLY (not the streak — a repo that
  # lists badly does NOT backoff the whole fleet, the forge is up since discovery succeeded). BUT the
  # RECONCILIATION state (`orphan_lock_suspects`, 2-tick grace) MUST persist cross-tick: without re-threading,
  # the grace never accumulates → an orphaned lock is NEVER reclaimed (the pipe wedges). We aggregate it
  # (union over all repos) in the returned state. `poll_count` +1/tick (observability).
  # The lock refs are REPO-QUALIFIED (`{repo, :issue|:pr, n}`, built in
  # `Reconciliation`): the cross-repo union of suspects no longer collides on the number
  # alone → a live pod #N/repoB NO LONGER masks an orphan #N/repoA, and the 2-tick grace no longer
  # contaminates across repos (no more double-spawn). The key carries the identity.
  defp do_poll(state) do
    forge = step_forge_client(state)

    case forge.list_org_repos(state.org, state.forge_opts) do
      {:ok, repos} ->
        base = %{state | err_streak: 0, poll_count: state.poll_count + 1, last_error: nil}

        # ADMISSION = ORG-MEMBERSHIP (WS3): every repo of the org IS a fleet project — the org is THE frontier
        # of the trust group, managed UPSTREAM by the human admin (LCARS is not adversarial multi-tenant).
        # No more mutable topic nor server-side seal to verify. Per-human scoping stays
        # `assigned_by` (issue-level, `step_do_poll`): the fleet processes ONLY its issues, even if
        # `list_org_repos` shows it the repos of the OTHER humans of the group (the anti-theft guard holds).
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
  # STEP mode — assignee-driven reactor (the forge IS the state machine; this module is its reactor).
  # Decoupled from the legacy AutoDispatcher: no routes, no Executor.
  # ============================================================

  defp step_do_poll(state) do
    started = System.monotonic_time()
    forge = step_forge_client(state)

    # Repo-serialized lease: we list ALL open items (in-flight included) to count the active
    # workflow_runs. We ALSO list the open PRs → the JUDGES are dispatched
    # via the PR's requested_reviewers (plus the issue assignee). decide skips the in-flight ones.
    # FORGE-SIDE multi-user scoping: SAME `assigned_by` filter for issues AND PRs (both go
    # through /issues?type=… on the ForgeClient side). The poller sees ONLY the items of ITS human → scoping lives in
    # ONE place (the list), decide/dispatch_review no longer re-check ownership. Per-human lease.
    scoped_opts = Keyword.put(state.forge_opts, :assigned_by, state.my_human)

    with {:ok, issues} <- forge.list_open_issues(state.repo, scoped_opts),
         {:ok, pulls} <- forge.list_open_pulls(state.repo, scoped_opts) do
      pr_issue_ids = pulls_issue_ids(pulls)

      # Lock reconciliation BEFORE dispatch: an orphaned `lcars-in-flight` (pod dead without having
      # completed → reaped, but the label survives on the forge side) would block the brick FOREVER
      # (`dispatch_*` skips `:in_flight`). We reclaim it (2-tick grace) → the next tick re-dispatches.
      # Without this, a single pod stall wedges the pipe permanently. The DECISION lives in
      # `Reconciliation` (reads 5 seams, yields the set of suspects); the 2-tick grace (`prior_suspects`) and
      # the cross-repo union stay HERE (cross-tick state). We resolve the prod defaults of the seams at THIS site.
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

      # dispatch opts computed ONCE/tick (shared issues + pulls), not 2×.
      opts = step_dispatch_opts(state)

      # SET of `lcars-awaits-arch` issues (already listed at the tick → ZERO added I/O), threaded
      # to the pulls via `:awaits_arch_ids` → `dispatch_review` skips the judge of a PR whose parent issue
      # awaits the arch (symmetric to `decide/1` on the issue side). Without this: escalation places `awaits-arch` on
      # the ISSUE but `dispatch_review` reads ONLY the PR's labels → judge re-spawn every tick (churn).
      awaits_arch_ids = awaits_arch_ids(issues)
      pulls_opts = Keyword.put(opts, :awaits_arch_ids, awaits_arch_ids)

      # G4: throttled re-kick of the arch as long as an issue awaits its action (the initial kick at escalation
      # is one-shot; a lost wake → issue blocked forever otherwise).
      maybe_rekick_arch(awaits_arch_ids, state)

      tally =
        Lease.merge_tally(
          Lease.process_issues(issues, pr_issue_ids, opts, lease_seams(state)),
          step_process_pulls(pulls, pulls_opts)
        )

      duration_ms = elapsed_ms(started)

      # A successful tick = SILENT. This poll is a ~30s cron in a loop; logging every nominal pass
      # (most often dispatched=0, nothing to do) drowns the trace under hundreds of routine
      # lines. The metrics (duration, dispatched/skipped/errors) go to telemetry below;
      # poll failures are logged (handle_poll_error) and each per-item dispatch traces at its own
      # level. We log when it breaks, not when it runs.
      :telemetry.execute(
        [:fleet_pilot, :poller, :poll],
        %{duration_ms: duration_ms},
        Map.merge(tally, %{status: :ok, mode: :step, repo: state.repo})
      )

      # The forge list succeeded, but PER-ITEM `dispatch_*` may have failed
      # (`tally.errors > 0` — e.g. broker enqueue KO, spawn KO). We compute a per-repo
      # `err_streak` here, BUT the multi-project `do_poll` currently DISCARDS it (it aggregates
      # only `orphan_lock_suspects` and forces `err_streak` back to 0 each tick, cf. `do_poll`)
      # → this partial backoff does NOT take effect; dispatch errors still surface via
      # `last_tally_errors`/telemetry, never as slowdown.
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

  # SET of issue numbers carrying `lcars-awaits-arch`. Derived from the `issues` ALREADY listed
  # by the tick (no extra forge call) → threaded to the pulls (`:awaits_arch_ids`) so that
  # `dispatch_review` skips the judge of a PR whose parent issue awaits the arch.
  defp awaits_arch_ids(issues) do
    for i <- issues, n = i["number"], awaits_arch?(i), into: MapSet.new(), do: n
  end

  # G4 — RE-KICK the arch as long as at least one issue awaits its action (`lcars-awaits-arch`). The initial
  # kick (at escalation, StepRunConsumer.kick_architect) is one-shot best-effort: if the wake was
  # lost (arch busy, or dead-then-respawned by the PermanentWarden), the issue stays out-of-dispatch
  # FOREVER, silently (the poller only SKIPS it). So we re-kick periodically —
  # THROTTLED (`@awaits_rekick_every` ticks) because a wake can cost a claude turn (bounded spend,
  # Jupiter). Best-effort (the label stays human-released: we nudge the airlock, we never force the verdict).
  # Resolves `state.spawner || Fleet.Spawner` at the call site (symmetric to reconciliation_seams /
  # lease_seams) + the authority `Roles.architect_pod_id/0` (SSOT shared with kick_architect). Prod
  # does NOT inject the seam → the REAL `Fleet.Spawner` is used (best-effort: `{:error, :not_found}`
  # if the arch pod is dead, discarded by `_ =`). (Was a silent no-op in prod — the seam had no
  # default and the guard `when not is_nil(spawner)` fell through — the rail this exists for never ran.)
  defp maybe_rekick_arch(awaits_ids, %__MODULE__{} = state) do
    if awaits_rekick?(MapSet.size(awaits_ids), state.poll_count) do
      spawner = state.spawner || Fleet.Spawner
      pod_id = Fleet.Pilot.Roles.architect_pod_id()

      Logger.info(
        "Poller: #{MapSet.size(awaits_ids)} issue(s) awaits-arch → re-kick #{pod_id} " <>
          "(throttle #{@awaits_rekick_every} ticks)"
      )

      _ = spawner.wake_pod(pod_id)
    end

    :ok
  end

  @doc false
  # PURE re-kick decision: at least ONE issue awaits the arch AND we are on a tick multiple of the
  # throttle. Exposed (test) — the computation is the load-bearing core (the wake itself is a seam delegation).
  @spec awaits_rekick?(non_neg_integer(), non_neg_integer()) :: boolean()
  def awaits_rekick?(awaits_size, poll_count)
      when is_integer(awaits_size) and is_integer(poll_count) do
    awaits_size > 0 and rem(poll_count, @awaits_rekick_every) == 0
  end

  defp awaits_arch?(item) do
    @awaits_arch in Enum.map(Map.get(item, "labels") || [], & &1["name"])
  end

  # Issues carrying an open fleet PR (`lcars/issue-N-role`) = workflow_runs in JUDGE phase:
  # the producer is done, the rest is dispatched via the pulls -> the issue path SKIPS them
  # (otherwise the poller would re-spawn the producer, still assigned).
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

  # PR-driven path: each open PR with a requested review → dispatch the judge.
  # Not guarded by the lease (the judges of an ALREADY active workflow_run must advance; the lease bounds
  # only the ENTRY of new workflow_runs, on the issues side).
  defp step_process_pulls(pulls, opts) do
    Enum.reduce(pulls, Lease.zero_tally(), fn pr, acc ->
      case StepDispatcher.dispatch_review(pr, opts) do
        # `:ok` covers `{:spawned, _, _}` (judge/rework spawned) AND `{:merged, _}` (PR sealed).
        {:ok, _} -> %{acc | dispatched: acc.dispatched + 1}
        {:skipped, _reason} -> %{acc | skipped: acc.skipped + 1}
        {:error, _reason} -> %{acc | errors: acc.errors + 1}
      end
    end)
  end

  # Hardened boundary to `Lease` (repo-serialized lease): the 5 authorized reads, prod defaults
  # resolved HERE (same rule as `Reconciliation.Seams`: we resolve at the construction site).
  defp lease_seams(state) do
    %Lease.Seams{
      forge: step_forge_client(state),
      repo: state.repo,
      forge_opts: state.forge_opts,
      workflow_map_loader: state.workflow_map_loader || Fleet.Workflow.Loader,
      incident_fun: state.incident_fun || (&Fleet.Pilot.IncidentRegistry.record_or_escalate/4)
    }
  end

  # Builds the opts for StepDispatcher.dispatch_issue. The seams
  # (loader/spawner/task_queue) are injected ONLY if they are set on the
  # state — otherwise StepDispatcher applies its real defaults (passing nil
  # would overwrite the default).
  # `:task_queue` is carried by the state (resolved at the call site of `Reconciliation.reconcile`) and MUST
  # be passed here, otherwise StepDispatcher falls back to the global `Fleet.TaskQueue` for the brief enqueue
  # (broker seam not honored on the dispatch side).
  defp step_dispatch_opts(state) do
    [
      repo: state.repo,
      forge_client: step_forge_client(state),
      forge_opts: state.forge_opts
    ]
    |> Opts.maybe_put(:loader, state.loader)
    # `workflow_map_role` (dispatch) loads the route's workflow_map → it needs the WORKFLOW_MAP loader (as a
    # load!/1 function). Live: nil → default `Fleet.Workflow.Loader.load!` (priv). Test: derived from the stub
    # module. (Distinct from `:loader` = cap-profiles.)
    |> Opts.maybe_put(:workflow_map_loader, workflow_map_loader_fun(state))
    |> Opts.maybe_put(:spawner, state.spawner)
    |> Opts.maybe_put(:task_queue, state.task_queue)
    # Threaded down to `dispatch_issue`: only nil falls back to the real default (the real `WakeRecovery.wake/3`).
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
