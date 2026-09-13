defmodule Fleet.Pilot.Poller do
  @moduledoc """
  Polls forge issues and PRs across configured catalogue organisations, delegating
  dispatch to StepDispatcher. Discovery is followed by a local ops-directory guard
  and parked-marker check; finding a repository does not onboard it.

  Issues and PRs are listed with assigned_by set to this fleet's human. Lease bounds
  entry into new workflow runs per human and repository; PR processing advances
  existing runs outside that ceiling. Admission shares tally and wait-label handling.
  Reconciliation owns lock decisions; this process retains suspects across polls.

  Regular ticks take one pod snapshot, reconcile locks, keep registered architects,
  offer awaits-arch work and recheck branch protection. Webhook hints ignore payload
  and debounce into a separate dispatch poll; they neither start a recurring timer
  chain nor advance reconciliation observations. force_poll/1 performs a full tick.

  Discovery errors and failures escaping the repository fold increase backoff.
  Returned per-repository list errors and item errors affect tallies instead.
  Repository exceptions are logged/escalated and preserve prior suspects; failure
  in that escalation can still escape to the outer catch. Effects already made
  are not rolled back when the previous process state is returned.

  Configuration: :human defaults to Human.current!(); organisation precedence is
  nonempty :orgs, :org, :pilot_fleet_org, then installed catalogue names. :repo is
  ignored at init and only used internally while iterating. :interval_ms defaults
  to 30_000; Backoff supplies jitter and delay. :start_tick? defaults true;
  :subscribe_gitea defaults false and is enabled by Pilot.Application.
  :forge_opts and the dependency seams in the state support transport and tests.

  Telemetry :poll measures individual repositories (plus discovery failures);
  :cycle measures discovery through the serial repository/global passes. Its served
  count rechecks the onboarding predicate: it is not a receipt for successful work
  or for passing the parked gate. Crashes need not emit cycle telemetry.
  """

  use GenServer
  require Logger

  alias Fleet.Forge.Payload
  alias Fleet.Opts
  alias Fleet.Pilot.IncidentRegistry
  alias Fleet.Pilot.Poller.Reconciliation
  alias Fleet.Pilot.StepDispatcher

  alias Fleet.Pilot.Poller.Backoff

  alias Fleet.Pilot.Poller.Lease

  alias Fleet.Pilot.Poller.Admission

  # Forward issue-level awaits-arch to PR dispatch using the existing issue listing.
  @awaits_arch Fleet.Labels.awaits_arch()

  @default_interval_ms 30_000

  # Cooldown follows a successful net wake, so the first eligible tick is not
  # delayed by a sampling grid. It is global across repositories.
  @awaits_rekick_cooldown_ms 300_000

  # Coalescence window of the webhook kick: a burst of events within the window = ONE poll.
  @gitea_kick_debounce_ms 1_000

  # Recheck protection on regular ticks; new repositories are due immediately.
  # Successful checks wait one hour; returned errors remain due next tick.
  @protection_recheck_ms 3_600_000

  defstruct [
    :repo,
    :interval_ms,
    # Forge-list assignment filter for this fleet's human.
    :my_human,
    # Organisation membership supplies discovery scope, not local onboarding.
    :orgs,
    :forge_client_override,
    forge_opts: [],
    loader: nil,
    workflow_map_loader: nil,
    spawner: nil,
    task_queue: nil,
    # Inject wake recovery to test lease accounting after a failed wake.
    wake_recovery: nil,
    # Workflow-map incident seam; nil selects record_or_escalate/4.
    incident_fun: nil,
    # Substrate and repository-crash escalation seam; nil selects escalate_gated/5.
    escalate_fun: nil,
    # Distinguish a missing project from a missing ops root in tests without
    # provisioning the real layout. Nil selects File.dir? on that root.
    substrate_present_fun: nil,
    # Log and record snapshot failure on transition; kicks leave this unchanged.
    pods_snapshot_ok?: true,
    # Branch-protection reconciliation seam; nil selects Project.Onboard.
    protection_reconciler: nil,
    # Architect keeper seam; nil selects Project.Architect.ensure_alive/2.
    architect_keeper: nil,
    # Per-repository monotonic stamps; restart makes checks due again.
    protection_rechecked: %{},
    # A scheduled accelerated poll coalesces subsequent webhook hints.
    gitea_kick_pending?: false,
    poll_count: 0,
    # Count hints separately from regular reconciliation observations.
    kick_count: 0,
    error_count: 0,
    err_streak: 0,
    last_error: nil,
    # Latest aggregate list/item errors, separate from discovery/outer-crash backoff.
    last_tally_errors: 0,
    # Stamp only :offered or :woken_pending. One successful repository can arm
    # this global cooldown even if another repository's wake failed.
    last_arch_rekick_at: nil,
    # Previous repo-qualified orphan observations. Kicks, list errors and skipped
    # repositories preserve their prior subset. Confirmation uses observations,
    # not a minimum wall-clock age; force_poll can advance it immediately.
    orphan_lock_suspects: MapSet.new(),
    # Organisations returning HTTP 404, used to log absence/recovery transitions.
    absent_orgs: MapSet.new()
  ]

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
    # Resolve discovery and human scope at startup; a fixed :repo option is ignored.
    state = %__MODULE__{
      my_human: Keyword.get(opts, :human) || Fleet.Credentials.Human.current!(),
      orgs: resolve_orgs(opts),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      forge_client_override: Keyword.get(opts, :forge_client),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      loader: Keyword.get(opts, :loader),
      workflow_map_loader: Keyword.get(opts, :workflow_map_loader),
      spawner: Keyword.get(opts, :spawner),
      task_queue: Keyword.get(opts, :task_queue),
      wake_recovery: Keyword.get(opts, :wake_recovery),
      incident_fun: Keyword.get(opts, :incident_fun),
      escalate_fun: Keyword.get(opts, :escalate_fun),
      substrate_present_fun: Keyword.get(opts, :substrate_present_fun),
      protection_reconciler: Keyword.get(opts, :protection_reconciler),
      architect_keeper: Keyword.get(opts, :architect_keeper)
    }

    _ =
      if Keyword.get(opts, :start_tick?, true) do
        schedule(Backoff.jitter(state.interval_ms))
      end

    # Webhooks are hints to re-read forge state; payloads are ignored.
    # Opt-in avoids stray Bus events in tests; production enables subscription.
    _ =
      if Keyword.get(opts, :subscribe_gitea, false) do
        :ok = Fleet.EventRouter.Bus.subscribe()
      end

    Logger.info(
      "Poller: start mode=step MULTI-PROJECT orgs=#{Enum.join(state.orgs, ",")} human=#{state.my_human} " <>
        "interval=#{state.interval_ms}ms jitter=±10%"
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    # Include synchronous scheduled work in shutdown draining.
    {_result, new_state} = Fleet.Shutdown.Quiesce.busy(fn -> safe_poll(state) end)
    schedule(Backoff.next_delay(new_state.err_streak, new_state.interval_ms))
    {:noreply, new_state}
  end

  # Use a dedicated kick message: injecting :poll would start another recurring chain.
  def handle_info(%Fleet.Event{type: type}, %__MODULE__{} = state) do
    if gitea_event?(type) and not state.gitea_kick_pending? do
      _ = Process.send_after(self(), :gitea_kick, @gitea_kick_debounce_ms)
      {:noreply, %{state | gitea_kick_pending?: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:gitea_kick, state) do
    # A kick accelerates dispatch without advancing regular reconciliation or net work.
    {_result, new_state} =
      Fleet.Shutdown.Quiesce.busy(fn ->
        safe_poll(%{state | gitea_kick_pending?: false}, :kick)
      end)

    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp gitea_event?(type) when is_atom(type),
    do: String.starts_with?(Atom.to_string(type), "gitea.")

  @impl GenServer
  # Full observation for tests/ops; unlike scheduled handlers, this call is not
  # wrapped in Quiesce.busy and does not schedule the next tick.
  def handle_call(:force_poll, _from, state) do
    {result, new_state} = safe_poll(state, :tick)
    {:reply, result, new_state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       # Expose current discovery scope to operators arriving after startup.
       orgs: state.orgs,
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

  # All entry points share exception/exit/throw handling for do_poll.
  defp safe_poll(state, mode \\ :tick) do
    do_poll(state, mode)
  rescue
    exception -> poll_crash(state, exception, "crash")
  catch
    kind, reason -> poll_crash(state, {kind, reason}, "exit/throw")
  end

  # Return the prior state plus failure counters. Forge writes and process-dictionary
  # changes already made during the failed poll are not reverted.
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

  # Treat HTTP 404 as an absent organisation and continue. Other returned errors
  # abort discovery, so a partial list cannot look like a complete work scan.
  defp discover(forge, state) do
    Enum.reduce_while(state.orgs, {:ok, [], []}, fn org, {:ok, acc, absent} ->
      case forge.list_org_repos(org, state.forge_opts) do
        {:ok, repos} -> {:cont, {:ok, acc ++ repos, absent}}
        {:error, {:http, 404, _}} -> {:cont, {:ok, acc, [org | absent]}}
        {:error, reason} -> {:halt, {:error, {org, reason}}}
      end
    end)
  end

  # Log absence and recovery transitions, including the provisioning command.
  defp note_absent_orgs(state, absent) do
    now = MapSet.new(absent)

    for org <- MapSet.difference(now, state.absent_orgs) do
      Logger.warning(
        "Poller: catalogue #{inspect(org)} has its material on this container but its org does NOT " <>
          "exist on the forge (404) — DROPPED from discovery. Nothing is hidden by the drop: an " <>
          "org that does not exist carries no repository. Replay `lcars catalogue install " <>
          "#{org}` (admin, inside the container) — it is convergent and it lays both halves."
      )
    end

    for org <- MapSet.difference(state.absent_orgs, now) do
      Logger.info("Poller: org #{inspect(org)} now exists on the forge — discovery resumes on it")
    end

    %{state | absent_orgs: now}
  end

  # Explicit scopes precede installed catalogue names.
  defp resolve_orgs(opts) do
    cond do
      is_list(orgs = Keyword.get(opts, :orgs)) and orgs != [] -> orgs
      is_binary(org = Keyword.get(opts, :org)) -> [org]
      is_binary(org = Application.get_env(:lcars_fleet, :pilot_fleet_org)) -> [org]
      true -> Fleet.Catalogue.installed_names()
    end
  end

  defp do_poll(state, mode) do
    # Include discovery latency, particularly on failed discovery.
    started = System.monotonic_time()
    forge = step_forge_client(state)

    case discover(forge, state) do
      {:ok, repos, absent} ->
        state = note_absent_orgs(state, absent)

        # Hints advance their own counter, never the regular-poll count.
        base =
          case mode do
            :tick -> %{state | err_streak: 0, poll_count: state.poll_count + 1, last_error: nil}
            :kick -> %{state | err_streak: 0, kick_count: state.kick_count + 1, last_error: nil}
          end

        # Snapshot pods once per regular tick and pass the value explicitly to each repo.
        # Kicks do not reconcile, so need no pod enumeration.
        pods =
          if mode == :tick,
            do: Reconciliation.snapshot_pods(state.spawner || Fleet.Spawner),
            else: :none

        base = note_pods_snapshot(base, pods)

        {tally, suspects, awaits} = fold_repos(repos, base, mode, pods)

        # Offer the cross-repository awaits union once per regular tick. ArchWake groups
        # it by project; this poller's successful-wake cooldown is fleet-wide.
        base = if mode == :tick, do: maybe_rekick_arch(awaits, base), else: base

        # Reconcile protection against current policy beyond the one-time onboarding write.
        base = if mode == :tick, do: maybe_recheck_protection(base, repos), else: base

        emit_cycle(started, mode, state.orgs, :ok, repos)

        {tally, %{base | orphan_lock_suspects: suspects, last_tally_errors: tally.errors}}

      {:error, reason} ->
        emit_cycle(started, mode, state.orgs, :error, [])

        handle_poll_error(state, {:discover_repos, reason}, started)
    end
  end

  # Isolate repository processing failures and preserve that repo's prior suspects.
  # Escalation in the error handler is not protected by this inner try.
  defp fold_repos(repos, base, mode, pods) do
    Enum.reduce(repos, {Lease.zero_tally(), MapSet.new(), MapSet.new()}, fn repo,
                                                                            {acc_t, acc_s, acc_a} =
                                                                              acc ->
      repo_state = %{base | repo: repo}

      try do
        {t, s, a} = step_do_poll(repo_state, mode, pods)
        {Lease.merge_tally(acc_t, t), MapSet.union(acc_s, s), MapSet.union(acc_a, a)}
      rescue
        e -> repo_poll_crash(repo_state, e, acc)
      catch
        kind, reason -> repo_poll_crash(repo_state, {kind, reason}, acc)
      end
    end)
  end

  # Whole-cycle latency includes discovery, pod snapshot, serial repo work and global
  # passes. served counts current onboarding predicates, even for parked/failed repos;
  # it distinguishes missing local projects from an idle fleet, not successful dispatch.
  defp emit_cycle(started, mode, orgs, status, repos) do
    :telemetry.execute(
      [:lcars_fleet, :pilot_poller, :cycle],
      %{
        duration_ms: elapsed_ms(started),
        repos: length(repos),
        served: Enum.count(repos, &onboarded?/1)
      },
      %{status: status, mode: mode, orgs: orgs}
    )
  end

  # Successful protection checks are throttled; returned errors retry next regular tick.
  defp maybe_recheck_protection(%__MODULE__{} = state, repos) do
    now = System.monotonic_time(:millisecond)

    due =
      Enum.filter(repos, fn repo ->
        now - Map.get(state.protection_rechecked, repo, now - @protection_recheck_ms - 1) >=
          @protection_recheck_ms
      end)

    reconciler =
      state.protection_reconciler ||
        (&Fleet.Project.Onboard.reconcile_main_protection/2)

    # Do not delay retry by stamping failed reconciliation.
    reconciled =
      Enum.filter(due, fn repo ->
        case reconciler.(repo, state.forge_opts) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning(
              "Poller: main-protection reconcile #{repo} FAILED (#{inspect(reason)}) — " <>
                "NOT stamped, retried at the NEXT TICK (the rule may be out of line with the " <>
                "current jury, or the forge was unreadable)"
            )

            false
        end
      end)

    %{
      state
      | protection_rechecked:
          Enum.reduce(reconciled, state.protection_rechecked, &Map.put(&2, &1, now))
    }
  end

  # Snapshot failure freezes reclamation. Log both failure and recovery transitions;
  # :none is a kick with no measurement, not evidence of recovery.
  defp note_pods_snapshot(%__MODULE__{} = state, :none), do: state

  defp note_pods_snapshot(%__MODULE__{} = state, {:error, reason}) do
    if state.pods_snapshot_ok? do
      Logger.warning(
        "Poller: pod enumeration FAILED reason=#{inspect(reason)} — nothing is reclaimed while " <>
          "this lasts (fail-safe), so an orphaned lock outlives its pod"
      )

      incident = state.incident_fun || (&IncidentRegistry.record_or_escalate/4)

      _ =
        try do
          # Use the stable container-level subject spawner, independent of catalogue order.
          incident.("pod_enumeration", "spawner", :spawner_unreachable,
            reason_detail: inspect(reason)
          )
        catch
          # Incident callback failures are logged without changing the snapshot fail-safe.
          kind, why ->
            Logger.warning(
              "Poller: incident rail unavailable for pod enumeration " <>
                "(#{inspect(kind)} #{inspect(why)}) — the fail-safe stands, its escalation does not"
            )
        end
    end

    %{state | pods_snapshot_ok?: false}
  end

  defp note_pods_snapshot(%__MODULE__{} = state, _pods) do
    if not state.pods_snapshot_ok? do
      Logger.info("Poller: pod enumeration RECOVERED — orphaned-lock reclamation resumes")
    end

    %{state | pods_snapshot_ok?: true}
  end

  # Returned discovery errors increase backoff; per-repo list errors do not.
  defp handle_poll_error(state, reason, started) do
    new_streak = state.err_streak + 1

    Logger.warning(
      "Poller: discovery error reason=#{inspect(reason)} streak=#{new_streak} " <>
        "(backoff arms the next tick)"
    )

    :telemetry.execute(
      [:lcars_fleet, :pilot_poller, :poll],
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
  # ============================================================

  defp step_do_poll(state, mode, pods) do
    started = System.monotonic_time()
    forge = step_forge_client(state)

    # Discovery must not implicitly clone or provision a project. Require its local
    # ops directory before listing work.
    if onboarded?(state.repo) do
      # Clear display memory after admission so a later disappearance logs again.
      Process.delete({__MODULE__, :not_onboarded_logged, state.repo})
      step_do_poll_onboarded(state, mode, pods, started, forge)
    else
      not_onboarded_skip(state, repo_scoped_suspects(state))
    end
  end

  # Regular ticks keep registered architects for onboarded, unparked projects.
  # Shared project directories do not prove this container owns an architect;
  # ensure_alive checks its registry and does not create an unregistered one.
  defp keep_architect(state) do
    keeper = state.architect_keeper || (&Fleet.Project.Architect.ensure_alive/2)
    _ = keeper.(state.repo, state.forge_opts)
    :ok
  end

  # Preserve only this repo's suspects, avoiding resurrection of another repo's
  # resolved locks. The error is escalated but adds nothing to the returned tally.
  defp repo_poll_crash(state, reason, {acc_t, acc_s, acc_a}) do
    Logger.error(
      "Poller: repo=#{state.repo} RAISED during its poll (#{inspect(reason)}) — this repo is " <>
        "skipped for this tick, the others are NOT. The cause is usually deterministic (the same " <>
        "PR, the same file), so it will repeat until someone looks."
    )

    escalate = state.escalate_fun || (&IncidentRegistry.escalate_gated/5)

    _ =
      escalate.(
        :repo_poll_crash,
        state.repo,
        {:poll_raised, reason},
        "repo_poll_crash:#{state.repo}",
        state.forge_opts || []
      )

    {acc_t, MapSet.union(acc_s, repo_scoped_suspects(state)), acc_a}
  end

  defp repo_scoped_suspects(state),
    do: MapSet.filter(state.orphan_lock_suspects, fn {r, _type, _n} -> r == state.repo end)

  # Presence of the ops directory is the admission predicate, not proof of a complete
  # onboarding. :pilot_require_onboarded is disabled by config/test.exs for fictional
  # repos; production defaults true. Positive filesystem behavior belongs on the bench.
  defp onboarded?(repo) do
    if Application.get_env(:lcars_fleet, :pilot_require_onboarded, true),
      do: File.dir?(project_work_dir(repo)),
      else: true
  end

  defp project_work_dir(repo),
    do: Path.join(Fleet.Layout.ops_root(), Fleet.Layout.project_name(repo))

  # Log a missing project once until it passes admission again.
  defp not_onboarded_skip(state, repo_prior) do
    # A missing ops root is a substrate incident, distinct from one missing project.
    present? = state.substrate_present_fun || fn -> File.dir?(Fleet.Layout.ops_root()) end

    if present?.() do
      unless Process.get({__MODULE__, :not_onboarded_logged, state.repo}) do
        Process.put({__MODULE__, :not_onboarded_logged, state.repo}, true)

        Logger.warning(
          "Poller: repo=#{state.repo} discovered in the org but NOT ONBOARDED (no ops at " <>
            "#{project_work_dir(state.repo)}) — step rail skipped. Serving it would engrave routes " <>
            "and dispatch without provenance or project doctrine. Onboard it " <>
            "(create / import / open / adopt) to bring it in."
        )
      end
    else
      substrate_gone(state)
    end

    {Lease.zero_tally(), repo_prior, MapSet.new()}
  end

  # Attempt substrate escalation once per process, across all repos. The flag is set
  # before escalation and is not cleared on recovery; an error is not retried here.
  defp substrate_gone(state) do
    unless Process.get({__MODULE__, :substrate_gone_logged}) do
      Process.put({__MODULE__, :substrate_gone_logged}, true)

      root = Fleet.Layout.ops_root()

      Logger.error(
        "Poller: the ops root #{root} is ABSENT or unreadable — the step rail is skipped for " <>
          "EVERY repo, not just #{state.repo}. This is not an un-onboarded project: the substrate " <>
          "itself is gone (unmounted, permissions), and the fleet is running empty while the " <>
          "telemetry reports zero counts."
      )

      escalate = state.escalate_fun || (&IncidentRegistry.escalate_gated/5)

      _ =
        escalate.(
          :ops_root_missing,
          root,
          {:ops_root_absent, root},
          "ops_root_missing:#{root}",
          state.forge_opts || []
        )
    end

    :ok
  end

  defp step_do_poll_onboarded(state, mode, pods, started, forge) do
    repo_prior = repo_scoped_suspects(state)

    # List in-flight items too for lease accounting. Scope both listings to this
    # human; the stubs and downstream selectors may perform additional checks.
    scoped_opts = Keyword.put(state.forge_opts, :assigned_by, state.my_human)

    with {:ok, issues} <- forge.list_open_issues(state.repo, scoped_opts),
         {:ok, pulls} <- forge.list_open_pulls(state.repo, scoped_opts) do
      step_do_poll_parked_or_live(state, mode, started, {issues, pulls}, repo_prior, pods)
    else
      {:error, reason} ->
        # Preserve this repo's suspect history on a list error; awaits are unknown.
        # Count the failure without slowing all repositories via backoff.
        tally = log_repo_list_error(state, reason, started)
        {tally, repo_prior, MapSet.new()}
    end
  end

  # Detect the parked marker in the human-scoped issue listing already fetched.
  defp step_do_poll_parked_or_live(state, mode, started, {issues, pulls}, repo_prior, pods) do
    if parked?(issues) do
      parked_skip(state, repo_prior)
    else
      Process.delete({__MODULE__, :parked_logged, state.repo})
      if mode == :tick, do: keep_architect(state)
      step_do_poll_live(state, mode, started, issues, pulls, repo_prior, pods)
    end
  end

  defp parked?(issues),
    do: Enum.any?(issues, &Fleet.Forge.Protocol.parked_issue_title?(&1["title"]))

  # Parked repos skip dispatch, reconciliation and awaits collection, preserving
  # suspects. Protection reconciliation still runs outside this per-repo path.
  # Clear the log flag on unpark so a later park is announced.
  defp parked_skip(state, repo_prior) do
    unless Process.get({__MODULE__, :parked_logged, state.repo}) do
      Process.put({__MODULE__, :parked_logged, state.repo}, true)

      Logger.info(
        "Poller: repo=#{state.repo} PARKED (marker issue) — step rail skipped until reopened"
      )
    end

    {Lease.zero_tally(), repo_prior, MapSet.new()}
  end

  defp step_do_poll_live(state, mode, started, issues, pulls, repo_prior, pods) do
    forge = step_forge_client(state)

    pr_issue_ids = pulls_issue_ids(pulls)

    # Reconcile before dispatch; this pass still holds the pre-reclaim issue snapshot.
    # Reconciliation owns decisions, while this process retains grace observations.
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
            reconciliation_seams,
            pods
          )

        :kick ->
          # Hints must neither seed nor clear suspects: webhook traffic during publication
          # must not advance the regular observation grace.
          repo_prior
      end

    # Share dispatch options between the issue and PR paths within this repo.
    opts = step_dispatch_opts(state)

    # PR labels do not carry their issue's awaits-arch; forward the per-repo set.
    awaits_arch_ids = awaits_arch_ids(issues)

    # Forward issue wait labels too, avoiding an issue lookup per skipped PR.
    pulls_opts =
      opts
      |> Keyword.put(:awaits_arch_ids, awaits_arch_ids)
      |> Keyword.put(:wait_labels, wait_labels(issues))

    tally =
      Lease.merge_tally(
        Lease.process_issues(issues, pr_issue_ids, opts, lease_seams(state)),
        step_process_pulls(pulls, pulls_opts)
      )

    duration_ms = elapsed_ms(started)

    # Nominal passes emit telemetry without a routine log line.
    :telemetry.execute(
      [:lcars_fleet, :pilot_poller, :poll],
      %{duration_ms: duration_ms},
      Map.merge(tally, %{status: :ok, mode: :step, repo: state.repo})
    )

    # Item failures affect tally/telemetry, not the discovery backoff streak.
    {tally, new_suspects, MapSet.new(awaits_arch_ids, &{state.repo, &1})}
  end

  # Discovery succeeded, but that does not prove the forge remains healthy.
  # Policy records repo-list failure without increasing the fleet backoff streak.
  defp log_repo_list_error(state, reason, started) do
    Logger.warning(
      "Poller: per-repo list failure repo=#{state.repo} reason=#{inspect(reason)} " <>
        "— no backoff (forge up, discovery succeeded)"
    )

    :telemetry.execute(
      [:lcars_fleet, :pilot_poller, :poll],
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

  # Reuse listed issue labels to block their PRs while awaiting the architect.
  defp awaits_arch_ids(issues) do
    for i <- issues, n = i["number"], awaits_arch?(i), into: MapSet.new(), do: n
  end

  # Re-offer work still labelled awaits-arch if an earlier wake was lost.
  # This helper never removes labels. Resolve defaults even when seams are nil.
  defp maybe_rekick_arch(awaits_ids, %__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)

    if awaits_rekick?(MapSet.size(awaits_ids), state.last_arch_rekick_at, now) do
      spawner = state.spawner || Fleet.Spawner
      task_queue = state.task_queue || Fleet.TaskQueue

      case Fleet.Pilot.ArchWake.offer_then_wake(task_queue, spawner, awaits_ids, "net") do
        sent when sent in [:offered, :woken_pending] ->
          Logger.info(
            "Poller: #{MapSet.size(awaits_ids)} issue(s) awaits-arch (fleet-wide) → net #{sent} " <>
              "(cooldown #{div(@awaits_rekick_cooldown_ms, 1000)}s armed)"
          )

          %{state | last_arch_rekick_at: now}

        # No aggregate success: leave cooldown unstamped for a later regular tick.
        _no_signal_sent ->
          state
      end
    else
      state
    end
  end

  @doc false
  # First nonempty observation is eligible; subsequent successful net wakes impose cooldown.
  @spec awaits_rekick?(non_neg_integer(), integer() | nil, integer()) :: boolean()
  def awaits_rekick?(awaits_size, last_kick_at, now_ms)
      when is_integer(awaits_size) and is_integer(now_ms) do
    awaits_size > 0 and
      (is_nil(last_kick_at) or now_ms - last_kick_at >= @awaits_rekick_cooldown_ms)
  end

  defp awaits_arch?(item) do
    @awaits_arch in Payload.label_names(item)
  end

  # An open fleet PR keeps its issue off producer dispatch while the PR path advances it.
  defp pulls_issue_ids(pulls) do
    pulls
    |> Fleet.Forge.Protocol.fleet_prs_by_issue()
    |> Enum.map(fn {n, _pr} -> n end)
    |> MapSet.new()
  end

  # PR processing advances existing work outside the lease's new-entry ceiling.
  defp step_process_pulls(pulls, opts) do
    wait_labels = Keyword.get(opts, :wait_labels, %{})

    # Sort PRs by parent issue number so scarce role capacity follows ticket order
    # rather than the forge's recently-updated ordering.
    pulls
    |> Enum.sort_by(&pr_issue_number/1)
    |> Enum.reduce(Lease.zero_tally(), fn pr, acc ->
      # Parse the parent from the feature branch; nil suppresses issue wait-label writes.
      issue_n = pr_issue_number(pr)

      # Share accounting/wait policy, but do not consume a new-run lease for PR progress.
      {acc2, _started?} =
        Admission.admit(
          fn -> StepDispatcher.dispatch_review(pr, opts) end,
          opts,
          issue_n,
          Map.get(wait_labels, issue_n),
          acc
        )

      acc2
    end)
  end

  # Reuse existing issue labels for PR-path wait convergence.
  defp wait_labels(issues) do
    for i <- issues,
        n = i["number"],
        label = Admission.current_wait(i),
        into: %{},
        do: {n, label}
  end

  defp pr_issue_number(pr) do
    case Fleet.Forge.Protocol.parse_feature_branch(Payload.head_ref(pr) || "") do
      {:ok, {n, _role}} -> n
      _ -> nil
    end
  end

  # Resolve production defaults when constructing the lease seam bundle.
  defp lease_seams(state) do
    %Lease.Seams{
      forge: step_forge_client(state),
      repo: state.repo,
      forge_opts: state.forge_opts,
      workflow_map_loader: state.workflow_map_loader || Fleet.Workflow.Loader,
      incident_fun: state.incident_fun || (&IncidentRegistry.record_or_escalate/4)
    }
  end

  # Omit nil seams so StepDispatcher keeps its defaults. Thread the task queue to
  # dispatch as well as reconciliation; otherwise enqueue would reach the global broker.
  defp step_dispatch_opts(state) do
    [
      repo: state.repo,
      forge_client: step_forge_client(state),
      forge_opts: state.forge_opts
    ]
    |> Opts.maybe_put(:loader, state.loader)
    # Pass the workflow loader module so safe_load can retain catalogue-aware load!/2.
    # A unary wrapper would discard that scope. :loader separately loads role profiles.
    |> Opts.maybe_put(:workflow_map_loader, state.workflow_map_loader)
    |> Opts.maybe_put(:spawner, state.spawner)
    |> Opts.maybe_put(:task_queue, state.task_queue)
    |> Opts.maybe_put(:wake_recovery, state.wake_recovery)
  end

  defp step_forge_client(%__MODULE__{forge_client_override: nil}), do: Fleet.Forge.Client
  defp step_forge_client(%__MODULE__{forge_client_override: fc}), do: fc

  defp elapsed_ms(started_native) do
    System.convert_time_unit(
      System.monotonic_time() - started_native,
      :native,
      :millisecond
    )
  end
end
