defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle do
  @moduledoc """
  REVIEW (PR) lifecycle of `Fleet.Pilot.StepDispatcher`.

  `StepDispatcher.dispatch_review/2` (PUBLIC — the poller's contract) stays at the core: it does the PR
  gate (`in-flight`/`awaits-arch`), reads `pr_review_state` (commit-scoped verdicts + stable jury) THEN
  DELEGATES all routing here. This module carries the ROUTING (`dispatch_by_verdicts/5`) + the sealed
  PROMOTION (`promote_pr`); the flow's two other clusters descend into sub-modules:

    * `RoleDispatch` — shared EXECUTION leaf: prepares and spawns ONE role on the PR
      (judge / rework / resolution). It's the cut that makes the graph acyclic: routing AND
      remediation both converge on it (splitting routing↔rework in two would have created a cycle).
    * `Remediation` — BOUNDED rework/conflict (forge-native rework budget + honest merge-failure
      classification) → beyond that, arch escalation, never infinite churn.

  Promotion stays HERE: its error-path (`{:error, {:merge, _}}`) immediately re-enters
  routing (`Remediation.route_merge_failure`, which re-reads the PR object and classifies the REAL
  cause) — the merge/failure pair reads as one piece at the decision level.

  ## UNI-directional dependency (no cycle)

  ReviewLifecycle → `RoleDispatch`/`Remediation` → `Spawn` (SINGLE-AUTHORITY spawn leaf) +
  `ArchEscalation` (writing the human escalation) + `GatekeeperSeal` (merge seal, EXTERNAL authority
  shared with `StepRunCompleter.promote`) → ø. This module NEVER NAMES `StepDispatcher`:
  the review flow descends toward the leaves, it doesn't climb back to the core. The core DECIDES (PR
  gate + verdicts read), ReviewLifecycle ROUTES, the leaves EXECUTE.

  ## Boundary: `%Ctx{}` seams struct (hardened, `@enforce_keys`)

  The review flow needs a large context (forge/loader/spawner/task_queue/resolver/repo/forge_opts/
  wake_recovery/opts). Unlike the NARROW seams of `Spawn`/`ArchEscalation` (6 / 3 fields, one
  leaf cluster), this context is the dispatch's full package — hence a DEDICATED struct rather than a
  bare map: `@enforce_keys` forces every field at construction (SINGLE site: `StepDispatcher.
  dispatch_review/2`) and a `ctx.<typo>` access does not compile (where `Map.get(ctx, :typo)` would pass
  silently). The sub-modules re-build `Spawn.Seams`/`ArchEscalation.Seams` from this `Ctx` at the
  call site of each leaf (narrow boundary preserved).

  ## Helpers SHARED with the core — taken at the SOURCE, no cycle, no fork

  `Spawn.route_for/4` (reads the engraved route) and `Opts.tag_err/2` (resolution error
  tag) serve BOTH flows (issue at the core + review here) from their authority modules —
  no captures in the `Ctx`: taking them at the source keeps the
  core→ReviewLifecycle→Spawn uni-directionality without a fn in a struct, without a fork.

  **Last revised**: 2026-07-18
  """

  require Logger

  # SINGLE-AUTHORITY spawn leaf: `safe_kill/2` (die-on-promote) — same authority as the
  # judge/rework spawn (via RoleDispatch), never a fork.
  alias Fleet.Pilot.StepDispatcher.Spawn

  # BOUNDED remediation (rework forge-native budget / merge-failure classification) — DECIDES, then
  # descends back onto RoleDispatch (producer re-spawn) or ArchEscalation (human wall).
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation

  # EXECUTION leaf of the PR-role spawn (judge/rework/resolution): read-only resolutions then
  # Spawn.spawn_step. Shared by routing ↔ remediation (the flow's acyclic cut).
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  defmodule Ctx do
    @moduledoc """
    Full context of the review flow, built at the SINGLE site `StepDispatcher.dispatch_review/2` and
    threaded through routing/rework/promotion. DEDICATED struct (not a map): `@enforce_keys`
    forces every field, a `ctx.<typo>` access does not compile. (No fn captures: both flows
    take `Spawn.route_for`/`Opts.tag_err` at the source.)
    """
    @enforce_keys [
      :forge,
      :loader,
      :workflow_map_loader,
      :spawner,
      :task_queue,
      :resolver,
      :repo,
      :forge_opts,
      :wake_recovery,
      :opts
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            # Injected forge client (seam `:forge_client`, prod default `Fleet.Pilot.ForgeClient`).
            forge: module(),
            # Injected cap-profile loader (seam `:loader`, prod default `Fleet.CapProfile`).
            loader: module(),
            # Injected workflow_map loader (seam `:workflow_map_loader`, default `&Fleet.Workflow.Loader.load!/1`) —
            # reads the map-level rework budget (`spec.max_rework_rounds`) on the PR rework path.
            workflow_map_loader: (String.t() -> map()),
            # Injected spawner (seam `:spawner`, prod default `Fleet.Spawner`).
            spawner: module(),
            # Injected brief broker (seam `:task_queue`, prod default `Fleet.TaskQueue`).
            task_queue: module(),
            # Injected project resolver (seam `:project_resolver`, default `&default_project_resolver/2`).
            resolver: (String.t(), keyword() -> {:ok, map() | nil} | {:error, term()}),
            # Repo `owner/name` (the PR + parent issue live there).
            repo: String.t(),
            # Forge opts (base_url/token…) passed to the ForgeClient.
            forge_opts: keyword(),
            # Injected wake recovery (seam `:wake_recovery`, default `&Fleet.Pilot.WakeRecovery.wake/3`).
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()}),
            # The raw dispatch `opts` keyword (base of `review_opts`; source of the `:reviewer_roles` override).
            opts: keyword()
          }
  end

  # ============================================================
  # Routing (review flow entry)
  # ============================================================

  @doc """
  REVIEWS-DRIVEN routing (the source of truth = the posted reviews, NOT `requested_reviewers`
  which Gitea does not clear). Without branch-protection: LCARS aggregates (user decision). ORDER:
    1. a requested judge WITHOUT a decisive verdict → active round → we spawn it (serialized by the PR lock).
       A judge already decisive (even if still listed in requested_reviewers) is NOT re-spawned → end of
       the re-spawn loop.
    2. all requested have a verdict + at least one `:changes_requested` → producer rework.
    3. all requested have APPROVED → MERGE (gatekeeper-sealed).
    4. no requested judge → ADOPTION: PR discovered without setup (typ. HUMAN/fork) → we LAY the judges
       (reviewer_roles) → normal review on the next tick. Agent-agnostic gate: origin doesn't matter.

  Entry point of the review flow: `StepDispatcher.dispatch_review/2` delegates here after the PR gate + the
  read of `pr_review_state`. `requested` = union(volatile requested_reviewers, stable jury);
  `verdicts` = commit-scoped `login → verdict` map.
  """
  @spec dispatch_by_verdicts([String.t()], map(), integer(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch_by_verdicts(requested, verdicts, pr_number, head, %Ctx{} = ctx) do
    pending = requested -- Map.keys(verdicts)

    cond do
      pending != [] ->
        RoleDispatch.dispatch(:judge, pr_number, head, hd(pending), ctx)

      requested == [] ->
        adopt_orphan_pr(pr_number, ctx)

      Enum.any?(Map.values(Map.take(verdicts, requested)), &(&1 == :changes_requested)) ->
        Remediation.dispatch_rework(pr_number, head, ctx)

      true ->
        # All approved → MERGE. A merge failure is NOT necessarily a conflict: we re-read the PR object
        # and route on the REAL cause (`route_merge_failure`: already-merged / cancelled / draft / policy
        # re-request / real conflict / unknown) — never a catch-all "conflict", never a seal
        # claimed before the merge holds.
        case promote_pr(pr_number, head, ctx) do
          {:error, {:merge, reason}} ->
            Remediation.route_merge_failure(pr_number, head, reason, ctx)

          other ->
            other
        end
    end
  end

  # ADOPTION — a PR with NO judge at all (neither volatile requested_reviewers nor stable jury) was not set
  # up by the pipeline: typically a HUMAN PR (fork + cross-repo) that the poller discovered + scoped
  # (via the linked issue `Closes #N`). The gate is AGENT-AGNOSTIC → we LAY the judges (reviewer_roles, system
  # token via forge_opts); on the next tick `requested` carries them → normal review → merge/rework, EXACTLY
  # like an agent deliverable. An agent PR ALWAYS has its judges via open_deliverable_pr → never reaches
  # here. A laying failure surfaces as `{:error, {:adopt_failed, _}}` — counted in the poller's
  # `tally.errors` (telemetry + last_tally_errors) and RETRIED next tick (`requested` still empty →
  # same adoption path re-runs). No crash, no silent skip.
  # Idempotent: re-laying the same reviewers = Gitea no-op (an adopted PR is never re-adopted: requested ≠ []).
  defp adopt_orphan_pr(pr_number, %Ctx{} = ctx) do
    reviewers = Fleet.Pilot.Roles.jury(nil, ctx.opts)

    case ctx.forge.request_review(ctx.repo, pr_number, reviewers, ctx.forge_opts) do
      :ok -> {:ok, {:adopted, pr_number, reviewers}}
      {:error, reason} -> {:error, {:adopt_failed, reason}}
    end
  end

  # ============================================================
  # Promotion (gatekeeper-sealed merge)
  # ============================================================

  # PROMOTE PR-state-driven (interim, without branch-protection): all judges have
  # approved → the system SEALS. Closing comment + merge signed GATEKEEPER
  # (the PRs' keeper — "it's in the name"; role token, `as_role`). HONEST comment
  # (we don't lie, we show): delivered by the eng, validated by the judges (APPROVED), merged
  # by the system (branch-protection OFF in dev → LCARS aggregates, not Gitea — made explicit). The
  # `rebase` merge (LINEAR, handles a `main` advanced under a parallel PR — multi-issue, cf. merge_pr) —
  # `seal_and_merge` closes the issue EXPLICITLY, AFTER the comment (never `Closes #N`/Gitea
  # auto-close: coherent chronology). No lock (single-process poller); PR already
  # merged → 409 → the PR disappears on the next tick (idempotent).
  #
  # `promote_comment` + the gatekeeper role + the merge live in `Fleet.Pilot.GatekeeperSeal`
  # (SINGLE seal shared with `StepRunCompleter.promote` — no fork of the merge signature).
  defp promote_pr(pr_number, head, %Ctx{} = ctx) do
    with {:ok, {issue_n, producer}} <- RoleDispatch.parse_feature_branch_or_skip(head) do
      # SINGLE seal shared with `StepRunCompleter.promote`: gatekeeper comment + gatekeeper-signed
      # merge. The signature is applied INTERNALLY by `seal_and_merge` (single writer
      # `GatekeeperSeal.as_gatekeeper/1`) — a separate merge path would fork into a system token
      # (the escalation would sign `system`).
      case Fleet.Pilot.GatekeeperSeal.seal_and_merge(
             ctx.forge,
             ctx.repo,
             pr_number,
             issue_n,
             producer,
             ctx.forge_opts
           ) do
        :ok ->
          # Die-on-promote (return discarded — honestly: the producer is `one-shot`, ALREADY dead at
          # the end of build/rework → this kill is a no-op in the nominal case; a kill failure is
          # swallowed by `safe_kill`, and a leftover pod ends itself at end-of-run, its orphaned
          # substrate swept by Spawner's PodWarden). We DELIBERATELY keep `for_issue`
          # (not `for_repo`): for a `slot_scope: project` producer, `for_issue(issue_n, producer)`
          # targets a PHANTOM pod_id (`<repo>-issue-N-engineer` does not exist — the project identity is
          # `<repo>-engineer`) → SAFE no-op. Using `for_repo` here would KILL the eng if it's already coding
          # ANOTHER issue (shared project pod) = "kill the wrong eng" bug. To revisit ONLY if a
          # PIPE (long-lived) producer is reintroduced (targeted, non-naive cleanup needed then).
          _ =
            Spawn.safe_kill(ctx.spawner, Fleet.Pilot.PodId.for_issue(ctx.repo, issue_n, producer))

          # ISSUE lock — this poller-driven path must lift it ITSELF: the PR-lock lifts
          # via each judge's `StepRunCompleter.route(:reviewed)`, but the ISSUE-lock, started by the
          # PRODUCER at `dispatch_issue` and persisting through the whole review, is removed ONLY by
          # `StepRunCompleter.route(:promote)` — never reached on this path. `producer`
          # (parsed from the `lcars/issue-N-<role>` branch) IS the identity that started this stopwatch —
          # same `StepRunCompleter.unlock/5` authority as the workflow_map path (no fork).
          _ =
            Fleet.Pilot.StepRunCompleter.unlock(
              ctx.forge,
              ctx.repo,
              issue_n,
              ctx.forge_opts,
              producer
            )

          Logger.info(
            "StepDispatcher: PROMOTE pr=#{ctx.repo}##{pr_number} issue=##{issue_n} " <>
              "(judges OK → rebase merge, gatekeeper sealed, explicit close ; eng killed, issue lock released)"
          )

          {:ok, {:merged, pr_number}}

        {:error, _} = err ->
          err
      end
    end
  end
end
