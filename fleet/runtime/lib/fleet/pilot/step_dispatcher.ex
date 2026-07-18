defmodule Fleet.Pilot.StepDispatcher do
  @moduledoc """
  Dispatch `assigned issue → spawn the workflow_map's role`: the forge IS the state machine, this module
  reacts to its transitions. The poller sees an **assigned-to-me** issue (multi-user scoping carried
  forge-side, upstream), unlocked, and pushes it to its current step.

  ## Decision (`decide/1`) — pure GATE

  From a Gitea issue payload: `:engage` (proceed) | `{:skip, reason}` (`:in_flight` lock set,
  `:awaits_arch` human lock). decide does ONLY the gate — no ownership (forge-side scoping upstream),
  no role, no load (the ROLE comes from the workflow_map POSITION, via `workflow_map_role`; see Effects).

  ## Effects (`dispatch_issue/2`)

  On `:engage`: resolves project + route, then:
    * **route absent** (routeless issue — create_issue does not write it, or a raw human issue) →
      `ensure_workflow_map_or_onboard` writes the **default workflow_map** (brief-gate) → `{:skipped, :onboarded}`
      (we defer; the next tick sees it routed). This is the system ENTRY: create_issue creates, the poller routes.
    * **route present** → `workflow_map_role` derives `{role, profile, step_spec}` from the workflow_map POSITION (NO
      hardcoded producer — the route decides; route absent at this point = anomaly → fail-loud, never the eng
      silently), then the **canonical spawn order** (label `lcars-in-flight` BEFORE pod, else double-spawn).

  Judges are dispatched PR-driven via `dispatch_review/2` (requested_reviewers): the PR gate + the
  read of `pr_review_state` stay here, all the routing (verdicts / rework / conflict / promotion) is
  delegated to `Fleet.Pilot.StepDispatcher.ReviewLifecycle`. The modules
  `:forge_client` / `:loader` / `:workflow_map_loader` / `:spawner` are **seams** (defaults = real modules).

  **Last revised**: 2026-07-18
  """

  require Logger

  # Authority of the brief FORMAT (worker/judge/brief-review/rework/conflict). StepDispatcher
  # CHOOSES which brief per the forge state; BriefBuilder FORMS it.
  alias Fleet.Pilot.BriefBuilder

  # Single source of the "put the key IF non-nil" idiom (spawn_opts builders).
  alias Fleet.Pilot.Opts

  # REVIEW (PR) lifecycle extracted: `dispatch_review/2` (below, poller contract) does the PR gate +
  # reads `pr_review_state`, THEN delegates all the routing (verdicts / rework / conflict / promotion) to
  # `ReviewLifecycle.dispatch_by_verdicts/5`. Uni-directional dependency (core → ReviewLifecycle →
  # Spawn/ArchEscalation → ø). `route_for/4` + `tag_err/2` stay HERE (shared with `dispatch_issue`) and
  # are threaded to ReviewLifecycle by CAPTURE in the `%ReviewLifecycle.Ctx{}` — no fork, no cycle.
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle

  # SINGLE-AUTHORITY spawn leaf: the TWO flows (issue + review) CONVERGE on
  # `Spawn.spawn_step/9` (order lock→pod→enqueue→wake + compensation + `wake_unreached` contract),
  # `Spawn.pod_id_for_scope/4` (pod identity) and the scope gate (`project_scope_decision/4` +
  # `gate_scope_decision/1` + `maybe_reprovision/5`) — one copy each, never a fork. The core
  # DECIDES (route/role/verdict), Spawn EXECUTES (its naming helpers — rc_name / feature_slug /
  # maybe_put_route / resolve_repo_id — are shared with the review flow, one copy).
  alias Fleet.Pilot.StepDispatcher.Spawn

  # Protocol vocabulary = single source Fleet.Labels (compile-time constants).
  @in_flight_label Fleet.Labels.in_flight()
  @awaits_arch_label Fleet.Labels.awaits_arch()
  # Scoped label `stage/merged` (set by GatekeeperSeal BEFORE the close). Composed from the TWO
  # Labels authorities (prefix + value), not a forked literal.
  @merged_label Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged()

  @type decision :: :engage | {:skip, atom()}

  @doc """
  PURE decision (gate): issue payload → `:engage` | `{:skip, reason}`. decide does ONLY the
  gate: `lcars-in-flight` / `lcars-awaits-arch` lock → skip; else → `:engage` (proceed). The role AND
  the action (spawn vs onboard) are decided DOWNSTREAM (`dispatch_issue`) — hence `:engage` and not `:spawn`. The SCOPING
  (forge-side, upstream) and the ROUTING (route → role, via `workflow_map_role`/onboard in `dispatch_issue`) are
  NOT here — decide loads nothing and does not decide the role.
  """
  @spec decide(map()) :: decision()
  def decide(payload) when is_map(payload) do
    labels =
      payload
      |> Map.get("issue", payload)
      |> Map.get("labels", [])
      |> Enum.map(& &1["name"])

    cond do
      @in_flight_label in labels ->
        {:skip, :in_flight}

      # F-C066 — a MERGED brick is TERMINAL: never re-engaged, EVEN if its explicit close failed (issue
      # stuck OPEN). Without this durable guard, a merged-but-open issue (close failure inside
      # GatekeeperSeal) re-appears in `list_open_issues` → `decide/1` → re-dispatch → DOUBLE-DELIVERY. The
      # `stage/merged` label is the WS1 "done" marker (set before the close); a compromised-role fake is a
      # nuke&redeploy threat (same trust model as the other stage/* reads), not this rail's concern.
      @merged_label in labels ->
        {:skip, :merged}

      # HUMAN lock (gatekeeper verdict escalate/halt/redirect, or anomaly). The issue awaits
      # an action via the arch; the poller does NOT re-dispatch (else a judgment loop after the unlock).
      @awaits_arch_label in labels ->
        {:skip, :awaits_arch}

      true ->
        :engage
    end
  end

  @doc """
  Actual dispatch of an issue: `decide/1` then, on `:engage`, resolves project+route and either ONBOARDS
  (routeless → writes the default workflow_map → skip), or derives the role from the workflow_map (`workflow_map_role`) and
  applies the canonical spawn order (lock → pod → enqueue → wake, `spawn_step`). Idempotent.

  `opts`: `:repo` (mandatory), `:forge_opts` (passed to the ForgeClient), + seams
  `:forge_client` / `:loader` / `:workflow_map_loader` / `:spawner` / `:task_queue` (defaults = real modules).
  """
  @spec dispatch_issue(map(), keyword()) ::
          {:ok, {:spawned, pod_id :: String.t(), role :: String.t()}}
          | {:skipped, atom()}
          | {:error, term()}
  def dispatch_issue(payload, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    loader = Keyword.get(opts, :loader, Fleet.CapProfile)
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    task_queue = Keyword.get(opts, :task_queue, Fleet.TaskQueue)
    resolver = Keyword.get(opts, :project_resolver, &default_project_resolver/2)

    # Injectable workflow_map loader (seam, like the others) — makes `workflow_map_role` testable without disk.
    workflow_map_loader = Keyword.get(opts, :workflow_map_loader, &Fleet.Workflow.Loader.load!/1)

    case decide(payload) do
      {:skip, reason} ->
        {:skipped, reason}

      :engage ->
        issue = Map.get(payload, "issue", payload)
        number = issue["number"]
        repo = Keyword.fetch!(opts, :repo)
        forge_opts = Keyword.get(opts, :forge_opts, [])

        # Read-only pre-lock phase, CHEAP GATES FIRST: route/role read from the
        # poller's prefetch (local), then the LOCAL scope gate — the project resolver (the only
        # NETWORK call of the path, 1-2× `git ls-remote` ~15s worst case) runs LAST, on the
        # passing path only. With the resolver first, a recurring `:role_busy` tick would re-pay
        # it every 30s for nothing and, under a degraded forge, stall the whole sequential poll
        # tick. The forge LOCK (add_label in spawn_step) still comes after EVERYTHING here — a
        # transient failure anywhere in this phase leaves no orphan lock (invariant unchanged).
        # ROUTELESS = not yet onboarded (create_issue does not write it) → `ensure_workflow_map_or_onboard`
        # writes the default workflow_map + returns `{:onboarded, _}` → we DEFER (skip; the next tick sees it
        # routed). Routed → `workflow_map_role` derives the role from the workflow_map POSITION (NO hardcoded producer;
        # route absent at this point = post-onboard anomaly → fail-loud, NEVER the eng silently).
        # Route + workflow_map pre-read by the poller (lease classification) → reused via opts
        # (`resolve_route` / `:prefetched_workflow_map`) instead of a 2nd get_route + 2nd workflow_map load. Absent (tests,
        # other callers) → normal read/load (fallback).
        with {:ok, route} <-
               Opts.tag_err(
                 resolve_route(opts, forge, repo, number, forge_opts),
                 :route_resolution
               ),
             {:ok, route} <-
               ensure_workflow_map_or_onboard(
                 forge,
                 repo,
                 number,
                 route,
                 workflow_map_loader,
                 forge_opts
               ),
             {:ok, {role, profile, step_spec}} <-
               Opts.tag_err(
                 workflow_map_role(
                   route,
                   &loader.load/1,
                   workflow_map_loader,
                   Keyword.get(opts, :prefetched_workflow_map)
                 ),
                 :role_resolution
               ),
             # Pod identity + serialization READ from the catalogue, never guessed. `pod_id_for_scope/4`
             # takes the slot granularity (`slot_scope`, itself DERIVED from `lifetime_scope`: instance →
             # for_issue fan-out | project → for_repo, ONE identity/project). The scope DECISION keys on the
             # ROOT axis `lifetime_scope` DIRECTLY (not via the derived slot); it
             # gates BEFORE the resolver, its reprovision ACTION (needs project["base_sha"]) runs after.
             scope = Fleet.CapProfile.slot_scope(profile),
             pod_id = Spawn.pod_id_for_scope(scope, repo, number, role),
             slug = Spawn.feature_slug(issue),
             decision =
               Spawn.project_scope_decision(
                 Fleet.CapProfile.lifetime_scope(profile),
                 spawner,
                 pod_id
               ),
             :ok <- Spawn.gate_scope_decision(decision),
             {:ok, project} <- Opts.tag_err(resolver.(repo, opts), :project_resolution),
             :ok <- Spawn.maybe_reprovision(decision, spawner, pod_id, project, slug) do
          # pod_id and branch (`lcars/issue-N-role`) built independently from (n, role); pod_id
          # opaque (never re-parsed). The branch stays repo-LOCAL (no intra-repo collision).

          # The FORM of the brief (executable worker | disarmed judge) is read from the cap-profile
          # (`brief_kind`), NOT from a hardcoded magic name "gatekeeper" (differentiation-by-catalogue).
          # Computed ONCE → serves the spawn-file AND the TaskQueue brief (that the pod pulls via get_work_item).
          # Without it, enqueue_brief would re-enqueue the raw `issue["body"]` → a judge would pull the executable
          # BUILD brief instead of the GateBrief.
          case BriefBuilder.build_brief(
                 profile,
                 role,
                 forge,
                 repo,
                 number,
                 issue,
                 forge_opts,
                 route,
                 step_spec
               ) do
            {:ok, brief} ->
              spawn_opts =
                [
                  brief: brief,
                  pod_id: pod_id,
                  rc_name: Spawn.rc_name(repo, role),
                  # Speaking LOCAL branch name (sanitized issue title), not
                  # the pod_id. Used by phase.ex → `feature/<slug>`. Computed once (reused by the gate
                  # for the in-place reprovision of a pipe: same branch at reset as at spawn).
                  slug: slug
                ]
                |> Opts.maybe_put(:project, project)
                |> Spawn.maybe_put_route(route)
                |> Opts.maybe_put(:repo_id, Spawn.resolve_repo_id(forge, repo, forge_opts))

              # Spawn LEAF shared with dispatch_by_verdicts (lock → pod → enqueue → wake +
              # compensation). Producer: lock + issue_id keyed on the ISSUE (number). We build the
              # seams struct at this site (the 6 seams, not the whole `opts` — armored boundary).
              log_ctx =
                "issue=#{repo}##{number} " <>
                  "project=#{if(project, do: project["base_sha"], else: "none")} route=#{inspect(route)}"

              Spawn.spawn_step(
                %Spawn.Seams{
                  forge: forge,
                  spawner: spawner,
                  task_queue: task_queue,
                  repo: repo,
                  forge_opts: forge_opts,
                  # Wake recovery seam (default = the real fn) threaded from opts.
                  wake_recovery:
                    Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3)
                },
                pod_id,
                role,
                profile,
                brief,
                spawn_opts,
                number,
                number,
                log_ctx
              )

            # A DELIVERABLE-judge STEP (multi-step workflow_map) whose criterion (issue body)
            # can't be READ from the forge → we REFUSE a criterion-less judge (the diff without a criterion
            # → blind approval = false GREEN) and DEFER; the lock lives in `BriefBuilder`. A judge step
            # is instance-scoped (the scope gate returned `:proceed` WITHOUT a lock) → nothing to release;
            # the poller re-dispatches next tick (read-error ≠ absence).
            {:error, {:criterion_unavailable, reason}} ->
              Logger.warning(
                "StepDispatcher: judge criterion unavailable issue=#{repo}##{number} role=#{role} → " <>
                  "#{inspect(reason)} (skip, retry — refuse criterion-less judge)"
              )

              {:skipped, :criterion_unavailable}
          end
        else
          {:skipped, :role_busy} ->
            # Project-scoped role already occupied by another issue of the repo → DEFERRED without lock or
            # enqueue; the poller re-dispatches at the next tick (per-(repo,role) serialization via the
            # poll loop; the one-shot pod dies at the end of its task → fresh spawn for the next one).
            {:skipped, :role_busy}

          {:onboarded, _step} ->
            # Routeless issue onboarded onto the default workflow_map → we DEFER (skip; the next tick
            # sees it routed → dispatch). System entry: create_issue creates, the poller routes.
            {:skipped, :onboarded}

          {:error, {phase, reason}} ->
            Logger.warning(
              "StepDispatcher: #{phase} issue=#{repo}##{number} → #{inspect(reason)} (skip, no lock)"
            )

            {:error, {phase, reason}}
        end
    end
  end

  @doc """
  PR-driven dispatch of a JUDGE (review-request switch). An open PR with a requested review
  (`requested_reviewers`) -> spawns the judge role for the reviewer. Replaces the assignee-issue
  trigger for JUDGES (the producer stays issue-assignee-driven, via `dispatch_issue`).

  The pipeline-state (route = workflow_map position) stays on the ISSUE: `dispatch_review` walks back from
  `head.ref` (`lcars/issue-N-role`) to the issue and reads the written route. The `lcars-in-flight` lock
  is set on the PR (not the issue): it prevents the re-spawn of the judge between the spawn and the review
  being posted (after which Gitea removes the reviewer from `requested_reviewers`). Idempotent (PR lock +
  lock-comment dedup).

  The PR gate (in-flight / awaits-arch) + the construction of `ctx` + the read of `pr_review_state`
  live HERE; the routing (verdicts / rework / conflict / promotion) is DELEGATED to
  `ReviewLifecycle.dispatch_by_verdicts/5`.

  `pr`: Gitea map (`number`, `head.ref`, `requested_reviewers`, `labels`). `opts` as
  `dispatch_issue/2`. Returns `{:ok, {:spawned, pod_id, role}}` | `{:skipped, reason}` | `{:error, _}`.
  """
  @spec dispatch_review(map(), keyword()) ::
          {:ok, {:spawned, String.t(), String.t()}} | {:skipped, atom()} | {:error, term()}
  def dispatch_review(pr, opts) when is_map(pr) do
    # Full context of the review flow, built at this UNIQUE site and threaded to ReviewLifecycle. Armored
    # struct `%ReviewLifecycle.Ctx{}` (not a bare map): `@enforce_keys` forces each field, an access
    # `ctx.<typo>` does not compile. PURE data — no captures threaded: both flows take
    # Spawn.route_for/Opts.tag_err at the source; ReviewLifecycle never references this
    # module (uni-directional, no cycle).
    ctx = %ReviewLifecycle.Ctx{
      forge: Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient),
      loader: Keyword.get(opts, :loader, Fleet.CapProfile),
      workflow_map_loader:
        Keyword.get(opts, :workflow_map_loader, &Fleet.Workflow.Loader.load!/1),
      spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
      task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
      resolver: Keyword.get(opts, :project_resolver, &default_project_resolver/2),
      repo: Keyword.fetch!(opts, :repo),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      # Wake recovery seam (default = the real fn) threaded from opts.
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      opts: opts
    }

    pr_number = pr["number"]
    head = get_in(pr, ["head", "ref"]) || ""
    head_sha = get_in(pr, ["head", "sha"])
    labels = Enum.map(Map.get(pr, "labels") || [], & &1["name"])

    # The SET of judges is NOT read from `requested_reviewers` alone: Gitea alters that field
    # UNRELIABLY (a judge can DISAPPEAR from it without having voted → merge on a half-jury). STABLE
    # source = the review-records (`pr_review_state.reviewers`, REQUEST_REVIEW included). We keep
    # `requested_reviewers` in a UNION (defensive: a freshly-requested one not yet in the records). Logins↓.
    requested_field = pr |> Map.get("requested_reviewers") |> List.wrap() |> Enum.map(&login_of/1)

    # No ownership check here: the PR scoping is FORGE-SIDE upstream (list_open_pulls returns
    # ONLY my PRs via /issues?type=pulls&assigned_by). dispatch_review only does judgment dispatch.
    cond do
      @in_flight_label in labels ->
        {:skipped, :in_flight}

      # PR put back to DRAFT by a human = parked: it is NOT ready for review
      # (Gitea also refuses its merge, "Work in progress PRs cannot be merged"). We do NOT dispatch
      # a judge on it — else we would judge/merge work that the human explicitly paused. The `draft`
      # field is ALREADY in the PR shape (get_pull) — free read, complete decision guard
      # (the machine reads the complete gating forge-state).
      Map.get(pr, "draft") == true ->
        {:skipped, :draft}

      # The parent ISSUE carries `lcars-awaits-arch` (escalation: gatekeeper verdict
      # escalate/halt/redirect, or a conflict not auto-resolved) → we do NOT re-dispatch the judge (else churn:
      # re-spawn per tick). SYMMETRIC to `decide/1` on the issue side. The SET comes from the POLLER (issues already
      # listed at the tick → `:awaits_arch_ids`, ZERO added I/O); absent (other callers/tests) → `MapSet.new()`
      # → unchanged behavior (back-compat). We read the label on the ISSUE, not on the PR: it is the issue that
      # freezes (the escalation sets the human lock on it), the PR knows nothing of it — hence the blindness otherwise.
      awaits_arch_issue?(head, opts) ->
        {:skipped, :awaits_arch}

      true ->
        # head_sha → COMMIT-SCOPED verdicts: a review on an earlier commit (REQUEST_CHANGES never
        # dismissed by Gitea on push) is STALE → its judge goes back to `pending` → re-dispatched on the
        # current code (else infinite rework).
        verdict_opts = Keyword.put(ctx.forge_opts, :head_sha, head_sha)

        case ctx.forge.pr_review_state(ctx.repo, pr_number, verdict_opts) do
          {:ok, %{verdicts: verdicts, reviewers: jury}} ->
            # SET of judges = union(VOLATILE requested_reviewers, STABLE review-records). A judge
            # dropped from `requested_reviewers` without voting stays in the jury → `pending` → spawned, never a
            # merge on a half-jury (cf. ForgeClient.pr_review_state).
            #
            # F-C061 — the jury is RESTRICTED to the configured judge roles (`reviewer_roles`, the SSOT the
            # WRITE side lays via `request_reviews_step`). A reviewer login that is NOT a configured judge —
            # a HUMAN (verified live: humans keep ≥read on fleet repos, the forge does NOT prevent a human
            # review) or a non-jury role — is NOT a spawn target and does NOT count in the merge decision.
            # Otherwise it STARVES the jury (`hd(pending)` = human → silent `{:skipped, :no_role}`) or skews
            # the verdict tally. `brief_kind: judge` was NOT used here: it is a SECURITY axis (defused brief)
            # that also tags the gatekeeper (a verdict-reader/sealer, not a jury member) — the jury axis is
            # `reviewer_roles`. A foreign reviewer is surfaced LOUD (not swallowed), never a crash (a benign
            # human review must not DoS the pipe).
            jury_roles = MapSet.new(Fleet.Pilot.Roles.reviewer_roles(opts), &String.downcase/1)

            {requested, foreign} =
              Enum.split_with(Enum.uniq(requested_field ++ jury), &MapSet.member?(jury_roles, &1))

            warn_foreign_reviewers(foreign, ctx.repo, pr_number, jury_roles)
            ReviewLifecycle.dispatch_by_verdicts(requested, verdicts, pr_number, head, ctx)

          {:error, reason} ->
            {:error, {:review_state, reason}}
        end
    end
  end

  # Does the PR's parent issue (deduced from `head.ref` = `lcars/issue-<n>-<role>`) await
  # the arch? The `:awaits_arch_ids` SET is computed by the poller (issues of the tick, zero I/O) and threaded via
  # opts; default `MapSet.new()` (back-compat, other callers). Non-fleet PR (`:error`) → false (nothing to skip).
  defp awaits_arch_issue?(head, opts) do
    ids = Keyword.get(opts, :awaits_arch_ids, MapSet.new())

    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, {n, _role}} -> MapSet.member?(ids, n)
      :error -> false
    end
  end

  defp login_of(r), do: r |> Map.get("login", "") |> to_string() |> String.downcase()

  # A reviewer login that is NOT a configured judge role is IGNORED from the jury (not a spawn
  # target, not counted) but SURFACED loud: a human (or non-jury role) posting/being-requested a review on
  # a fleet PR is a real, forge-permitted anomaly (the write side only ever lays `reviewer_roles`). Warning,
  # not a crash: a benign human review must NOT turn into a pipeline DoS. (The F-C061 tag in the
  # log below is pinned by a test assert.)
  defp warn_foreign_reviewers([], _repo, _pr_number, _jury_roles), do: :ok

  defp warn_foreign_reviewers(foreign, repo, pr_number, jury_roles) do
    Logger.warning(
      "StepDispatcher: dispatch_review (F-C061) — non-jury reviewer login(s) #{inspect(foreign)} on PR " <>
        "#{repo}##{pr_number} — IGNORED from the jury (reviewer_roles=#{inspect(MapSet.to_list(jury_roles))}). " <>
        "A non-fleet-judge (human?) reviewed/was-requested; the forge does not prevent it. Not dispatched, not counted."
    )
  end

  # WorkflowMap-driven role: derives `{role, profile, step_spec}` from the workflow_map POSITION (written route) +
  # profile load. route nil = anomaly → fail-loud (no producer fallback). WorkflowMap/step/
  # profile unresolved = misconfig → `{:error, _}` (fail-loud).
  # `prefetched_workflow_map`: workflow_map already loaded by the poller (lease classification) → we avoid a
  # 2nd load; `nil` (tests, other callers) → load via `workflow_map_loader` (fallback).
  @spec workflow_map_role(
          {String.t(), String.t()} | nil,
          (String.t() -> {:ok, Fleet.CapProfile.t()} | {:error, term()}),
          (String.t() -> map()),
          map() | nil
        ) :: {:ok, {String.t(), Fleet.CapProfile.t(), map()}} | {:error, term()}
  # Route nil = ANOMALY: the poller onboards every routeless one BEFORE dispatch (ensure_workflow_map_or_onboard)
  # → if we arrive here without a route, fail-loud, NEVER a silent eng fallback. The role ALWAYS comes from the
  # workflow_map position (written route).
  defp workflow_map_role(nil, _load_role, _workflow_map_loader, _prefetched_workflow_map),
    do: {:error, :unrouted}

  defp workflow_map_role(
         {workflow_map_name, step},
         load_role,
         workflow_map_loader,
         prefetched_workflow_map
       ) do
    with {:ok, workflow_map} <-
           workflow_map_or_load(prefetched_workflow_map, workflow_map_name, workflow_map_loader),
         {:ok, role} <- workflow_map_step_role(workflow_map, workflow_map_name, step),
         {:ok, profile} <- load_role.(role) do
      # We surface the whole STEP_SPEC (extensible) rather than an isolated field. build_brief
      # reads `brief_kind` there (per-step override: consultant worker → judge without a duplicate profile) AND
      # `judge_target` (judges the BRIEF vs a deliverable). No nil case: `workflow_map_step_role`
      # above already proved the step EXISTS in the map (unknown step → error before this line).
      step_spec = get_in(workflow_map, ["steps", step])
      {:ok, {role, profile, step_spec}}
    end
  end

  # WorkflowMap pre-loaded (poller) → reused; else loaded via the seam.
  defp workflow_map_or_load(nil, workflow_map_name, workflow_map_loader),
    do: load_workflow_map(workflow_map_name, workflow_map_loader)

  defp workflow_map_or_load(workflow_map, _pipeline, _workflow_map_loader),
    do: {:ok, workflow_map}

  # Route pre-read by the poller (classification) → reused here; absent → forge read.
  defp resolve_route(opts, forge, repo, number, forge_opts) do
    case Keyword.fetch(opts, :prefetched_route) do
      {:ok, route} -> {:ok, route}
      :error -> Spawn.route_for(forge, repo, number, forge_opts)
    end
  end

  # System onboarding. Route present → passthrough `{:ok, route}`. Route nil (routeless issue:
  # create_issue does not write the workflow_map; or a raw human issue) → writes the default workflow_map (brief-gate)
  # = it ENTERS the gate → `{:onboarded, step}` (dispatch_issue defers: skip this tick, the next one
  # sees it routed). Route posted by the SYSTEM (system forge token). Failure → `{:error, {:onboard, _}}`.
  defp ensure_workflow_map_or_onboard(
         _forge,
         _repo,
         _number,
         route,
         _workflow_map_loader,
         _forge_opts
       )
       when not is_nil(route),
       do: {:ok, route}

  defp ensure_workflow_map_or_onboard(forge, repo, number, nil, workflow_map_loader, forge_opts) do
    workflow_map_name = default_workflow_map()

    with {:ok, workflow_map} <- load_workflow_map(workflow_map_name, workflow_map_loader),
         {:ok, {step, _role}} <- Fleet.Pilot.WorkflowMapNav.first_step(workflow_map),
         {:ok, _} <- forge.post_route(repo, number, workflow_map_name, step, forge_opts) do
      {:onboarded, step}
    else
      err -> {:error, {:onboard, err}}
    end
  end

  # Default onboarding workflow_map (every routeless assigned issue enters it; default brief-gate: the
  # consultant reviews the brief BEFORE the eng). Data-catalogue, not a hardcoded magic name.
  defp default_workflow_map,
    do: Application.get_env(:fleet_pilot, :delegation_workflow_map, "brief-gate")

  # Delegated to the single authority (WorkflowMapNav.safe_load — same tag; the rescue lives there).
  defp load_workflow_map(workflow_map_name, workflow_map_loader),
    do: Fleet.Pilot.WorkflowMapNav.safe_load(workflow_map_loader, workflow_map_name)

  defp workflow_map_step_role(workflow_map, workflow_map_name, step) do
    case Fleet.Pilot.WorkflowMapNav.step_role(workflow_map, step) do
      {:ok, role} when is_binary(role) -> {:ok, role}
      _ -> {:error, {:workflow_map_step_unknown, workflow_map_name, step}}
    end
  end

  # ============================================================
  # Internals
  # ============================================================

  # Project resolution (base_sha / gate_base_sha pinned out-of-pod via `git ls-remote`) extracted into
  # `Fleet.Pilot.StepDispatcher.ProjectResolver` (isolated I/O cluster, quasi-pure). `default_project_resolver/2`
  # stays THIS module's PUBLIC API (default of the `:project_resolver` seam + called by the tests) →
  # `defdelegate` keeps the exact contract.
  defdelegate default_project_resolver(repo, opts), to: Fleet.Pilot.StepDispatcher.ProjectResolver
end
