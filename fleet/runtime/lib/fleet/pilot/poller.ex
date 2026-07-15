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
  awaits-arch re-kick (coupled to `poll_count`; fired ONCE per tick by `do_poll` on the
  cross-repo union — the arch pod is fleet-unique, a per-repo kick multiplied the wake).

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
  @awaits_arch Fleet.Labels.awaits_arch()

  @default_interval_ms 30_000

  # G4 — cadence for RE-KICKING the arch as long as at least one issue is waiting (`lcars-awaits-arch`). Throttled:
  # 1 wake every N REGULAR ticks (at ~30s/tick, N=10 = ~5 min). A wake can cost a claude TURN → un-throttled,
  # it would be a 30s churn (unbounded spend, anti-Jupiter). Frequent enough that a lost wake does not block
  # an issue FOREVER, rare enough not to hammer the human airlock.
  # ⚠ The unit is the REGULAR tick: webhook kick-polls (:kick mode) neither increment
  # poll_count nor call maybe_rekick_arch — counting them compressed « ~5 min » to ~10s under
  # forge activity generated by the arch's own wake (self-amplified spend, Z6e class).
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
    # Kick-polls (webhook hint, :kick mode) counted APART: poll_count is the unit of the
    # tick-cadenced invariants (G4 throttle, 2-tick grace) — a kick must not consume them.
    kick_count: 0,
    error_count: 0,
    err_streak: 0,
    last_error: nil,
    # nb of DISPATCH errors (per item) of the last tick. The forge list
    # (`list_open_*`) can succeed while some `dispatch_*` fail — these errors are surfaced
    # here for observability (`stats/1`) + telemetry; they do NOT feed `err_streak` (the
    # multi-project `do_poll` resets the streak to 0 each successful tick, keeping only
    # `orphan_lock_suspects`) → they do not trigger backoff.
    last_tally_errors: 0,
    # Lock reconciliation: refs `{repo, :issue|:pr, n}` seen ORPHANED (`lcars-in-flight` lock
    # without a live pod) at the previous tick. 2-REGULAR-tick grace (same grace as the PodWarden):
    # we only reclaim on the 2nd consecutive REGULAR tick (avoids unlocking a freshly dispatched pod
    # or one in the process of dying). Webhook kick-polls (:kick) pass this set through UNCHANGED —
    # counting kicks as ticks compressed the ~60s grace to ~2s under the forge traffic generated by
    # the completion sequence itself (reclaim mid-publication → double dispatch, Z6e class).
    orphan_lock_suspects: MapSet.new()
  ]

  # No `@type t`: the previous one omitted a third of the real fields and typed `repo` non-nil
  # (false since multi-project discovery) — a lying type nobody consumed (zero @spec referenced
  # it). The commented defstruct above IS the state contract; a type list that must be manually
  # mirrored rusts silently (same reason comment-counters are banned).

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
    # :kick mode = DISPATCH-ONLY (doctrine Z6e : le kick est un HINT, le tick régulier est la
    # vérité) : ni réconciliation (grace 2-tick calibrée en ticks RÉGULIERS), ni re-kick arch
    # (throttle G4 idem), ni poll_count. Un kick accélère le dispatch, il ne consomme aucune
    # horloge à ticks.
    {_result, new_state} = safe_poll(%{state | gitea_kick_pending?: false}, :kick)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp gitea_event?(type) when is_atom(type),
    do: String.starts_with?(Atom.to_string(type), "gitea.")

  @impl GenServer
  # force_poll = action OPÉRATEUR délibérée → un tick PLEIN (:tick), réconciliation comprise :
  # l'humain demande un vrai poll, pas un hint. (Les tests pilotent la grace 2-tick par
  # force_poll consécutifs — cette sémantique est un contrat.)
  def handle_call(:force_poll, _from, state) do
    {result, new_state} = safe_poll(state, :tick)
    {:reply, result, new_state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       poll_count: state.poll_count,
       kick_count: state.kick_count,
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
  # result), force_poll (which returns it) AND the webhook kick (`mode: :kick`, dispatch-only)
  # → none of them bypasses the rescue.
  defp safe_poll(state, mode \\ :tick) do
    do_poll(state, mode)
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
  defp do_poll(state, mode) do
    # `started` captured BEFORE the forge call: `list_org_repos` is precisely the SLOW call when
    # the forge degrades — capturing after it reported duration_ms≈0 on exactly the failure case
    # an operator watches for (blind metric where it matters most).
    started = System.monotonic_time()
    forge = step_forge_client(state)

    case forge.list_org_repos(state.org, state.forge_opts) do
      {:ok, repos} ->
        # :kick does NOT touch poll_count: it is the UNIT of the tick-cadenced invariants
        # (G4 throttle below, 2-tick grace in step_do_poll) — a webhook burst must not
        # consume those clocks (Z6e: the kick is a hint, the regular tick is the truth).
        base =
          case mode do
            :tick -> %{state | err_streak: 0, poll_count: state.poll_count + 1, last_error: nil}
            :kick -> %{state | err_streak: 0, kick_count: state.kick_count + 1, last_error: nil}
          end

        # ADMISSION = ORG-MEMBERSHIP (WS3): every repo of the org IS a fleet project — the org is THE frontier
        # of the trust group, managed UPSTREAM by the human admin (LCARS is not adversarial multi-tenant).
        # No more mutable topic nor server-side seal to verify. Per-human scoping stays
        # `assigned_by` (issue-level, `step_do_poll`): the fleet processes ONLY its issues, even if
        # `list_org_repos` shows it the repos of the OTHER humans of the group (the anti-theft guard holds).
        #
        # The fold accumulates exactly the two cross-repo monoids step_do_poll yields (tally merge,
        # suspects union) + the awaits-arch union — nothing else survives the per-repo pass.
        {tally, suspects, awaits} =
          Enum.reduce(repos, {Lease.zero_tally(), MapSet.new(), MapSet.new()}, fn repo,
                                                                                  {acc_t, acc_s,
                                                                                   acc_a} ->
            {t, s, a} = step_do_poll(%{base | repo: repo}, mode)
            {Lease.merge_tally(acc_t, t), MapSet.union(acc_s, s), MapSet.union(acc_a, a)}
          end)

        # G4 re-kick — FLEET-GLOBAL action on the UNIQUE arch pod, decided ONCE per tick on the
        # cross-repo union. Inside the per-repo loop it fired R times per throttle-tick (poll_count
        # is loop-invariant): R repos awaits-arch = R wakes of the SAME arch + R log lines each
        # claiming "throttle" — the trace lied about the throttle and undercounted the backlog.
        # REGULAR ticks only: a kick-poll firing it would compress the ~5 min throttle to the
        # webhook rate — and the woken arch generates the very webhooks that would re-wake it.
        if mode == :tick, do: maybe_rekick_arch(awaits, base)

        {tally, %{base | orphan_lock_suspects: suspects, last_tally_errors: tally.errors}}

      {:error, reason} ->
        handle_poll_error(state, {:discover_repos, reason}, started)
    end
  end

  # DISCOVERY path only (`list_org_repos` KO = the forge itself is down/degraded): feeds
  # err_streak → backoff. The per-repo list failures go through `log_repo_list_error/3`
  # (no streak, no backoff — policy F-037).
  defp handle_poll_error(state, reason, started) do
    new_streak = state.err_streak + 1

    Logger.warning(
      "Poller: discovery error reason=#{inspect(reason)} streak=#{new_streak} " <>
        "(backoff arms the next tick)"
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

  defp step_do_poll(state, mode) do
    started = System.monotonic_time()
    forge = step_forge_client(state)

    # Prior suspects REPO-SCOPED (the refs are repo-qualified precisely for this): the whole
    # cross-repo union here let an error/kick branch resurrect suspects RESOLVED on other
    # repos (grace bypassed → reclaim in the registration window of a freshly re-spawned pod).
    repo_prior =
      MapSet.filter(state.orphan_lock_suspects, fn {r, _type, _n} -> r == state.repo end)

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
        case mode do
          :tick ->
            Reconciliation.reconcile(
              issues,
              pulls,
              pr_issue_ids,
              repo_prior,
              reconciliation_seams
            )

          :kick ->
            # DISPATCH-ONLY (Z6e) : le kick ne réclame PAS, ne sème PAS, n'efface PAS — passthrough
            # strict des suspects (miroir de la branche d'erreur ci-dessous). La grace 2-tick est
            # calibrée en ticks RÉGULIERS (~30s) : compter les kicks la comprimait à ~2s sous le
            # trafic forge généré par la séquence de complétion elle-même → reclaim du lock
            # lcars-in-flight en pleine fenêtre de publication → double dispatch/double dépense.
            # Un kick qui SÈMERAIT des suspects serait le bug inverse (orphelin confirmé par le
            # tick régulier ≤30s après, à age <60s). La latence de reclaim reste gouvernée par
            # le tick régulier, inchangée.
            repo_prior
        end

      # dispatch opts computed ONCE/tick (shared issues + pulls), not 2×.
      opts = step_dispatch_opts(state)

      # SET of `lcars-awaits-arch` issues (already listed at the tick → ZERO added I/O), threaded
      # to the pulls via `:awaits_arch_ids` → `dispatch_review` skips the judge of a PR whose parent issue
      # awaits the arch (symmetric to `decide/1` on the issue side). Without this: escalation places `awaits-arch` on
      # the ISSUE but `dispatch_review` reads ONLY the PR's labels → judge re-spawn every tick (churn).
      # The G4 re-kick itself is NOT fired here: it is fleet-global (unique arch pod) → the set is
      # returned repo-QUALIFIED (issue numbers collide across repos) and `do_poll` kicks ONCE on the union.
      awaits_arch_ids = awaits_arch_ids(issues)
      pulls_opts = Keyword.put(opts, :awaits_arch_ids, awaits_arch_ids)

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

      # Per-item dispatch errors (broker enqueue KO, spawn KO) surface via `tally.errors` →
      # telemetry + `last_tally_errors` (aggregated by `do_poll`), NEVER as backoff: the forge is
      # UP (both lists succeeded), so slowing the whole fleet's poll would punish the wrong layer —
      # policy locked by test F-037. Only a DISCOVERY failure (do_poll) feeds `err_streak`.
      {tally, new_suspects, MapSet.new(awaits_arch_ids, &{state.repo, &1})}
    else
      {:error, reason} ->
        # Log + telemetry only: the per-repo error state is NOT threaded up (cross-tick error
        # counters live on the discovery path, `do_poll` — policy F-037: only DISCOVERY feeds
        # err_streak/backoff). Suspects: contribute THIS repo's prior subset unchanged (2-tick
        # grace preserved across a transient list failure — repo-scoped, so suspects resolved
        # on OTHER repos are not resurrected); awaits: unknown for this repo (nothing listed)
        # → empty.
        tally = log_repo_list_error(state, reason, started)
        {tally, repo_prior, MapSet.new()}
    end
  end

  # Per-repo list failure — DISTINCT from the discovery path (`handle_poll_error`): the forge is
  # UP (discovery succeeded this very poll), no backoff is armed and no streak exists on this
  # path — logging « streak=1 » perpetually suggested a backoff-in-progress that F-037
  # deliberately does not run here. Telemetry mirrors the log: no err_streak on this scope.
  defp log_repo_list_error(state, reason, started) do
    Logger.warning(
      "Poller: per-repo list failure repo=#{state.repo} reason=#{inspect(reason)} " <>
        "— no backoff (forge up, discovery succeeded; policy F-037)"
    )

    :telemetry.execute(
      [:fleet_pilot, :poller, :poll],
      %{duration_ms: elapsed_ms(started)},
      %{
        status: :error,
        scope: :repo_list,
        repo: state.repo,
        error: inspect(reason)
      }
    )

    %{Lease.zero_tally() | errors: 1}
  end

  # SET of issue numbers carrying `lcars-awaits-arch`. Derived from the `issues` ALREADY listed
  # by the tick (no extra forge call) → threaded to the pulls (`:awaits_arch_ids`) so that
  # `dispatch_review` skips the judge of a PR whose parent issue awaits the arch.
  defp awaits_arch_ids(issues) do
    for i <- issues, n = i["number"], awaits_arch?(i), into: MapSet.new(), do: n
  end

  # G4 — RE-KICK the arch as long as at least one issue awaits its action (`lcars-awaits-arch`). The initial
  # kick (at escalation, StepRunConsumer.kick_architect) is ONE-SHOT with no delivery guarantee: if the
  # wake was lost (arch busy, or dead-then-respawned by the PermanentWarden), the issue stays out-of-dispatch
  # FOREVER, silently (the poller only SKIPS it). The truth is the `lcars-awaits-arch` label on the forge,
  # re-read at every tick — and THIS re-kick is the rail that re-derives a wake from it, periodically.
  # THROTTLED (`@awaits_rekick_every` ticks) because a wake can cost a claude turn (bounded spend,
  # Jupiter). The re-kick only NUDGES the airlock (a wake, nothing more): the label stays human-released,
  # we never force the verdict.
  # Called ONCE per tick by `do_poll` on the CROSS-REPO union — the arch pod is unique (fleet
  # airlock), so the decision is fleet-level; `awaits_ids` is repo-qualified (`{repo, n}` — bare
  # issue numbers collide across repos) so the logged count is the honest fleet-wide backlog.
  # Resolves `state.spawner || Fleet.Spawner` at the call site (symmetric to reconciliation_seams /
  # lease_seams) + the authority `Roles.architect_pod_id/0` (SSOT shared with kick_architect). Prod
  # does NOT inject the seam → the REAL `Fleet.Spawner` is used. A failed wake (arch pod dead,
  # `{:error, :not_found}`) loses latency, never the backlog: the label persists on the forge, this
  # same re-kick fires again `@awaits_rekick_every` ticks later, and the PermanentWarden respawns the
  # arch in the interval. The log states the ACTUAL outcome — logging « re-kick » before the wake
  # made the trace lie whenever it failed. (Was a silent no-op in prod — the seam had no default
  # and the guard `when not is_nil(spawner)` fell through — the rail this exists for never ran.)
  defp maybe_rekick_arch(awaits_ids, %__MODULE__{} = state) do
    if awaits_rekick?(MapSet.size(awaits_ids), state.poll_count) do
      spawner = state.spawner || Fleet.Spawner
      task_queue = state.task_queue || Fleet.TaskQueue
      pod_id = Fleet.Pilot.Roles.architect_pod_id()

      # The arch is a context-long/UNIQUE worker (project/forever, cf. collapse 2026-07-13) — the FORGE is
      # its queue (the awaits-arch labels), it works ONE escalation at a time, SAME serialize-via-forge as
      # the engineer. If it is FREE (no active work-item), OFFER it the next one as a real work-item so
      # `get_work_item` RETURNS the ticket (cures the {done:true} blindness — sonde #4). Busy → we only wake
      # (the backlog stays on the forge; this re-offers next tick, once the arch submits + the label drains,
      # ArchInboxConsumer). Enqueue is safe on replay: a fresh one supersedes, and once enqueued the arch is
      # busy → not re-offered until it drains.
      unless arch_busy?(task_queue, pod_id) do
        offer_arch_mandate(task_queue, pod_id, awaits_ids)
      end

      rekick_wake(spawner, pod_id, MapSet.size(awaits_ids))
    end

    :ok
  end

  # "Busy" for the arch — a `forever` pod, ALWAYS alive → busy ≠ "the process runs" (it always does). Busy =
  # it holds an ACTIVE work-item. Same probe as the reconciliation (`pod_status` + `WorkItem.active?`): a PURE
  # Query Port, no side-effect — unlike `get_for_pod`, which would assign the pending + broadcast `assigned`.
  defp arch_busy?(task_queue, pod_id) do
    case task_queue.pod_status(pod_id) do
      {:ok, wi_state} -> Fleet.TaskQueue.WorkItem.active?(wi_state)
      _ -> false
    end
  end

  # Enqueue ONE escalation as an arbitration mandate. Stable pick = the smallest `{repo, n}` (deterministic
  # across ticks; not time-ordered, but the arch drains them one-by-one WITH the human — order is not
  # load-bearing). The mandate POINTS to the issue (the arch reads it via its forge tools); the `WorkItem`
  # has no `repo` field → repo+number travel in `metadata` (the ArchInboxConsumer correlates on it to drain
  # the label at `submit_result`). A failed enqueue loses only latency (the label persists → re-offered).
  defp offer_arch_mandate(task_queue, pod_id, awaits_ids) do
    {repo, n} = Enum.min(awaits_ids)

    attrs = %{
      issue_id: "issue-#{n}",
      role: "architect",
      brief:
        "Arbitrage requis : escalade sur l'issue `#{repo}##{n}`. Lis-la (`list_escalations` / " <>
          "`get_issue_status`), tranche avec ton humain, puis réponds (`comment_issue`) ou corrige+re-délègue. " <>
          "Ferme le work-item (`submit_result`) quand c'est traité — la fleet retire alors le label d'attente.",
      metadata: %{"awaits_arch" => true, "repo" => repo, "number" => n}
    }

    case task_queue.enqueue(pod_id, attrs) do
      {:ok, _} ->
        Logger.info("Poller: arch mandate enqueued #{repo}##{n} (arch was free) → get_work_item will serve it")

      {:error, reason} ->
        Logger.warning(
          "Poller: arch mandate enqueue KO (#{repo}##{n}) : #{inspect(reason)} — label intact, retry next tick"
        )
    end
  end

  defp rekick_wake(spawner, pod_id, count) do
    case spawner.wake_pod(pod_id) do
      :ok ->
        Logger.info(
          "Poller: #{count} issue(s) awaits-arch (fleet-wide) → re-kick #{pod_id} " <>
            "(throttle #{@awaits_rekick_every} ticks)"
        )

      other ->
        Logger.warning(
          "Poller: #{count} issue(s) awaits-arch (fleet-wide) — re-kick #{pod_id} " <>
            "UNREACHED (#{inspect(other)}) — label forge intact, retry in #{@awaits_rekick_every} ticks, " <>
            "PermanentWarden respawns the arch"
        )
    end
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
