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
  `ArchEscalation` (writing the human escalation) + `MergeAndPromote` (merge seal, EXTERNAL authority
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
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGate
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.VerdictException

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
            # Injected forge client (seam `:forge_client`, prod default `Fleet.Forge.Client`).
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
    3. all requested have APPROVED → MERGE (rail merge) puis promotion (rail décision).
    4. no requested judge → the CARD decides: a zero-judge card (`project_jury` == []) makes this
       the NOMINAL path → straight to the sealed merge (the provenance wall inside `merge_and_promote`
       stays the floor); a judged card makes it an ORPHAN (typ. HUMAN/fork PR discovered without
       setup) → ADOPTION: we LAY the card's jury → normal review on the next tick. Agent-agnostic
       gate: origin doesn't matter.

  Entry point of the review flow: `StepDispatcher.dispatch_review/2` delegates here after the PR gate + the
  read of `pr_review_state`. `requested` = union(volatile requested_reviewers, stable jury);
  `verdicts` = commit-scoped `login → verdict` map.
  """
  @spec dispatch_by_verdicts([String.t()], map(), map(), integer(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch_by_verdicts(requested, verdicts, findings, pr_number, head, %Ctx{} = ctx) do
    # The classification is NOT re-derived here: `Jury.review_outcome` is the single truth (also
    # carried, on the stable jury, by `pr_review_state.outcome` for the arch's status read) — a
    # divergence between what the gate does and what the status says would be a second truth.
    #
    # THE FULL ARITY, and naming the `/2` here was wrong: it cannot return `:gray_zone` at all
    # (the behaviour's contract says so, and Dialyzer holds it), so a reader who followed this
    # comment went looking for the gray zone in a function structurally incapable of producing
    # one. Same defect class this chantier paid for twice — a text describing a neighbouring
    # behaviour rather than the one under it.
    case Fleet.Forge.Client.Jury.review_outcome(
           requested,
           verdicts,
           findings,
           issue_card_verdict_policy(head, ctx),
           Fleet.Project.Roles.gatekeeper_role(ctx.opts)
         ) do
      {:pending, [next | _]} ->
        # THE BRANCH IS PARSED BEFORE THE GATE, and the order carries weight. A PR whose head is
        # not a fleet feature branch can never receive a judge — `RoleDispatch.dispatch` refuses it
        # on this very parse — so paying two forge reads, and possibly a bounded CI wait ending in
        # an escalation, to reach a conclusion already in hand is pure spend. The cost stayed
        # invisible while an unparseable head made `issue_card_ci/2` answer `:ignore`: the gate
        # short-circuited for the wrong reason, and the wrong reason paid the bill.
        with {:ok, _} <- RoleDispatch.parse_feature_branch_or_skip(head) do
          gate_then_dispatch(pr_number, head, next, ctx)
        end

      :no_jury ->
        # The CARD arbitrates (doc point 4): zero-judge card → this IS the nominal path, seal
        # directly; judged card → orphan PR, lay the card's jury (adoption). The arbitrating card
        # is THE ISSUE'S ENGRAVED one when a route exists (`wfmap/*` — an workshop-direct issue's
        # zero-judge choice is deliberate); the project's declared card only for a true orphan
        # (no route). Reading the project card unconditionally re-adopted brief-gate's judges
        # onto an ops PR every tick (faceproof bench).
        case issue_card_jury(head, ctx) do
          [] -> promote_or_route(pr_number, head, ctx)
          card_jury -> adopt_orphan_pr(pr_number, card_jury, ctx)
        end

      :changes_requested ->
        Remediation.dispatch_rework(pr_number, head, ctx)

      # C3 — ZONE GRISE : le jury a tout approuvé, la courbe de la carte refuse, personne n'a
      # arbitré. Une clause EXPLICITE et pas un fourre-tout : sans elle, le nouvel état tombait sur
      # un `case` sans clause — un CaseClauseError sur le chemin de verdict, c'est-à-dire un rail
      # mort au moment précis où il devait décider.
      #
      # Elle convoque l'arbitre — passe unique, bornée par un marqueur forge, auto-gatée par son
      # drapeau. Tout ce qui n'aboutit pas là remonte à l'architecte avec le motif qui NOMME le
      # barreau (non armé / dépensé / non convocable), parce qu'un humain qui lit un gel doit
      # pouvoir distinguer « la passe a échoué » de « la passe n'existe pas sur cette boîte ».
      :gray_zone ->
        VerdictException.dispatch(
          pr_number,
          head,
          findings,
          issue_card_verdict_policy(head, ctx),
          ctx
        )

      :approved ->
        # All approved → MERGE (sealed, honest failure routing — `promote_or_route`).
        promote_or_route(pr_number, head, ctx)
    end
  end

  # THE CI IS A PRE-CONDITION OF THE SUMMONS, not an afterthought at merge time. Until this gate,
  # the machine rail and the judgement rail never met: judges were spawned on code nobody had built,
  # and the red surfaced at the PROMOTE, after the tokens were spent. `CiGate` decides (the CARD
  # governs — `spec.ci`), and when it lets through, the fact it measured RIDES to the judge instead
  # of being re-derived there.
  defp gate_then_dispatch(pr_number, head, next, %Ctx{} = ctx) do
    case CiGate.decide(pr_number, head, ctx, fn -> issue_card_ci(head, ctx) end) do
      {:proceed, fact} ->
        RoleDispatch.dispatch(:judge, pr_number, head, next, with_ci_fact(ctx, fact))

      {:refuse, :ci_red, message} ->
        Remediation.ci_red_rework(pr_number, head, message, ctx)

      # Three clauses rather than one passthrough, and the verbosity is the point: the BL-6-48
      # reverse wall reads `lib/` for the reasons the fleet can actually EMIT, and a reason
      # forwarded through a bare variable is invisible to it — the label table would carry
      # entries nothing in the tree can be shown to produce.
      {:wait, :ci_pending} ->
        {:skipped, :ci_pending}

      {:wait, {:ci_head_unreadable, why}} ->
        {:skipped, {:ci_head_unreadable, why}}

      {:wait, {:ci_unreadable, why}} ->
        {:skipped, {:ci_unreadable, why}}

      {:wait, {:ci_deadline_unreachable, why}} ->
        {:skipped, {:ci_deadline_unreachable, why}}

      {:escalate, class, message} ->
        Remediation.ci_stalled(pr_number, head, class, message, ctx)
    end
  end

  # PROMOTE + honest failure routing: a merge failure is NOT necessarily a conflict — we re-read
  # the PR object and route on the REAL cause (`route_merge_failure`: already-merged / cancelled /
  # draft / policy re-request / real conflict / unknown) — never a catch-all "conflict", never a
  # seal claimed before the merge holds. SHARED by the all-approved path and the zero-judge card
  # path: same seal, same routing, no fork.
  defp promote_or_route(pr_number, head, %Ctx{} = ctx) do
    case promote_pr(pr_number, head, ctx) do
      {:error, {:merge, reason}} ->
        Remediation.route_merge_failure(pr_number, head, reason, ctx)

      other ->
        other
    end
  end

  # The issue's engraved card jury, when the head parses and a route is engraved; the project's
  # declared card otherwise. Same fallback shape as the completer's `step_run_jury` twin.
  defp issue_card_jury(head, %Ctx{} = ctx) do
    with {:ok, {issue_n, _producer}} <- RoleDispatch.parse_feature_branch_or_skip(head),
         {:ok, {map_name, _step}} <-
           Spawn.route_for(
             ctx.forge,
             ctx.repo,
             issue_n,
             ctx.forge_opts
           ),
         {:ok, %{"jury" => jury} = map} when is_list(jury) <-
           Fleet.Pilot.WorkflowMapNav.safe_load(
             ctx.workflow_map_loader,
             map_name,
             Fleet.Workflow.Loader.card_opts_for_repo(ctx.repo)
           ) do
      # Through Roles.jury/2 (not the raw key): the reviewer_roles injection seam keeps priority.
      Fleet.Project.Roles.jury(map, ctx.opts)
    else
      _ -> Fleet.Project.Roles.project_jury(ctx.repo, ctx.opts)
    end
  end

  # The card's VERDICT POLICY — the tolerance curve applied to what the judges MEASURED. Third of
  # the trio (`jury`, `ci`, `verdict_policy`), and the only one whose resolution does NOT live here:
  # `Roles.verdict_policy_for/4` owns it because the arch-facing surface needs the SAME answer, and
  # the two live in domains that cannot see each other. A copy on each side would drift silently —
  # the gate refusing while the status reads "approved" — which is the failure `review_outcome`'s
  # own @doc names as the reason it is factored at all.
  defp issue_card_verdict_policy(head, %Ctx{} = ctx) do
    case RoleDispatch.parse_feature_branch_or_skip(head) do
      {:ok, {issue_n, _producer}} ->
        Fleet.Project.Roles.verdict_policy_for(
          ctx.forge,
          ctx.repo,
          issue_n,
          Keyword.put(ctx.opts, :forge_opts, ctx.forge_opts)
        )

      # A head that is not a fleet feature branch has no engraved route to read. The project's own
      # card still governs it — same fallback as the jury and the CI policy, for the same PRs
      # (human PR, adopted orphan).
      _ ->
        Fleet.Project.Roles.project_verdict_policy(ctx.repo, ctx.opts)
    end
  end

  # The card's CI policy, read exactly like its jury and through the same fallback: the ISSUE's
  # engraved card when a route exists, the PROJECT's declared card otherwise. The sentence was here
  # before the code was — the jury fallback read the project card, this one answered a hardcoded
  # `:ignore`, and the divergence was invisible because the comment covered it. A PR with no
  # engraved route (human PR, adopted orphan) was therefore judged under the project's jury and
  # under no CI policy at all, on projects whose card demands one.
  # PUBLIC (@doc false) pour la meme raison que `retire_superseded` l'est : la propriete qui compte
  # n'est ni « le champ traverse le loader » (tenu par `LoaderV25Test`) ni « la porte gate sur
  # :required » (tenu par `CiGateTest`, policy bouchee) — c'est la JOINTURE des deux, et elle n'est
  # observable que d'ici. Le maillon EST le token compare, mais il ne vit plus ici : `Roles.ci/1`
  # est le site unique qui connait les valeurs de l'enum, pour qu'un renommage n'ait qu'un endroit
  # ou echouer. `CiGateTest` tient la jointure contre le loader canon.
  @doc false
  @spec issue_card_ci(String.t(), Ctx.t()) :: :required | :ignore
  def issue_card_ci(head, %Ctx{} = ctx) do
    with {:ok, {issue_n, _producer}} <- RoleDispatch.parse_feature_branch_or_skip(head),
         {:ok, {map_name, _step}} <-
           Spawn.route_for(
             ctx.forge,
             ctx.repo,
             issue_n,
             ctx.forge_opts
           ),
         {:ok, map} when is_map(map) <-
           Fleet.Pilot.WorkflowMapNav.safe_load(
             ctx.workflow_map_loader,
             map_name,
             Fleet.Workflow.Loader.card_opts_for_repo(ctx.repo)
           ) do
      Fleet.Project.Roles.ci(map)
    else
      _ -> Fleet.Project.Roles.project_ci(ctx.repo, ctx.opts)
    end
  end

  # The measured fact travels in the dispatch opts (`review_opts` -> `BriefBuilder`), never as a
  # second forge read: one dispatch, one CI truth.
  defp with_ci_fact(%Ctx{} = ctx, nil), do: ctx

  defp with_ci_fact(%Ctx{} = ctx, fact),
    do: %{ctx | opts: Keyword.put(ctx.opts, :ci_fact, fact)}

  # ADOPTION — a PR with NO judge at all (neither volatile requested_reviewers nor stable jury) on a
  # JUDGED card was not set up by the pipeline: typically a HUMAN PR (fork + cross-repo) that the poller
  # discovered + scoped (via the linked issue `Closes #N`). The gate is AGENT-AGNOSTIC → we LAY the
  # CARD's jury (`reviewers`, resolved by the caller; system token via forge_opts); on the next tick
  # `requested` carries them → normal review → merge/rework, EXACTLY like an agent deliverable. An agent
  # PR ALWAYS has its judges via open_deliverable_pr → never reaches here. A laying failure surfaces as
  # `{:error, {:adopt_failed, _}}` — counted in the poller's `tally.errors` (telemetry +
  # last_tally_errors) and RETRIED next tick (`requested` still empty → same adoption path re-runs).
  # No crash, no silent skip.
  # Idempotent: re-laying the same reviewers = Gitea no-op (an adopted PR is never re-adopted: requested ≠ []).
  defp adopt_orphan_pr(pr_number, reviewers, %Ctx{} = ctx) do
    case ctx.forge.request_review(ctx.repo, pr_number, reviewers, ctx.forge_opts) do
      :ok -> {:ok, {:adopted, pr_number, reviewers}}
      {:error, reason} -> {:error, {:adopt_failed, reason}}
    end
  end

  # ============================================================
  # Sortie du pipeline : merge signé chief, promotion signée gatekeeper
  # ============================================================

  # PROMOTE PR-state-driven (interim, without branch-protection): all judges have
  # approved → the pipeline EXITS. ⚠ CE COMMENTAIRE DÉCRIVAIT L'ANCIENNE CONDITIONNELLE — « signé
  # par la FONCTION qui a fermé la PR : gatekeeper sur une propre, chief sur un conflit résolu ».
  # Cette conditionnelle-là est morte (revue 2026-08-20) : la signature suit désormais le DOMAINE de
  # l'acte, pas l'histoire de la PR. Le merge est TOUJOURS signé chief, la promotion TOUJOURS
  # gatekeeper ; seule la MÉTHODE reste conditionnelle au conflit. HONEST comment
  # (we don't lie, we show): delivered by the eng, AVIS FAVORABLE of the judges (APPROVED), merged
  # by the system (branch-protection OFF in dev → LCARS aggregates, not Gitea — made explicit). The
  # `rebase` merge on the clean path (LINEAR, handles a `main` advanced under a parallel PR —
  # multi-issue, cf. merge_pr; a conflict-resolved PR merges in `merge`, its resolution IS a
  # merge commit) —
  # `merge_and_promote` closes the issue EXPLICITLY, AFTER the comment (never `Closes #N`/Gitea
  # auto-close: coherent chronology). No lock (single-process poller); PR already
  # merged → 409 → the PR disappears on the next tick (idempotent).
  #
  # `promote_comment` + the signer choice + the merge live in `Fleet.Pilot.MergeAndPromote`
  # (SINGLE seal shared with `StepRunCompleter.promote` — no fork of the merge signature).
  defp promote_pr(pr_number, head, %Ctx{} = ctx) do
    with {:ok, {issue_n, producer}} <- RoleDispatch.parse_feature_branch_or_skip(head) do
      # SINGLE seal shared with `StepRunCompleter.promote`: gatekeeper comment + gatekeeper-signed
      # merge. The signature is applied INTERNALLY by `merge_and_promote` (single writer
      # `Forge.Client.as_role/2` (rail décision)) — a separate merge path would fork into a system token
      # (the escalation would sign `system`).
      case Fleet.Pilot.MergeAndPromote.merge_and_promote(
             ctx.forge,
             ctx.repo,
             pr_number,
             issue_n,
             producer,
             ctx.forge_opts,
             head_branch: head,
             # The PR's own base, read at the dispatch_review single site (chantier face-projet):
             # the seal aligns the FACE worktree the merge landed on.
             base_branch: Keyword.fetch!(ctx.opts, :pr_base_branch)
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
            Spawn.safe_kill(ctx.spawner, Fleet.PodId.for_issue(ctx.repo, issue_n, producer))

          # ISSUE lock — this poller-driven path must lift it ITSELF: the PR-lock lifts
          # via each judge's `StepRunCompleter.route(:reviewed)`, but the ISSUE-lock, started by the
          # PRODUCER at `dispatch_issue` and persisting through the whole review, is removed ONLY by
          # `StepRunCompleter.route(:promote)` — never reached on this path. `producer`
          # (parsed from the `lcars/issue-N-<role>` branch) IS the identity that started this stopwatch —
          # same `StepRunCompleter.unlock/5` authority as the workflow_map path (no fork).
          # `:delivered` — THE terminal unlock of this path (issue lock, post-seal): types the
          # feed line "brique LIVRÉE" and triggers the arch's single informational wake.
          # (Missed on the first live round 2026-07-18: only the completer's promote carried
          # it — the poller promote, the path real rounds actually take, said "étape franchie".)
          #
          # CI-08 — the caller must NOT announce the retrait before its VERDICT. `merge_and_promote` has
          # just CLOSED the issue, so the OPEN-issue poll no longer revisits it: a lost unlock leaves a
          # residual `lcars-in-flight` + a stopwatch running forever with NO natural retry. We therefore
          # (a) VERIFY the verdict (no more `_ =` + a blanket "lock released" log that lied on failure),
          # (b) RETRY it bounded — this is the LAST reconciliation opportunity (idempotent: `unlock` no-ops
          # a removed label / a 409'd stopwatch), and (c) log per the ACTUAL outcome. We deliberately do NOT
          # fold the unlock into `MergeAndPromote.seal_and_finalize` (the Cible's other option): unlock
          # (stop_stopwatch + remove in-flight + emit) is a concern OWNED by `StepRunCompleter.unlock` (its
          # SOLE-AUTHORITY @doc), and the stop identity differs between callers (here the branch-parsed
          # `producer`; `route(:promote)` uses `producer_stop_role`) — folding it would couple the seal to
          # the lock/stopwatch lifecycle AND fork that identity. The convergence that matters is the shared
          # honesty discipline (verify-then-announce), not a physical merge.
          case finalize_issue_unlock(ctx, issue_n, producer) do
            :ok ->
              # ⚠ CE LOG DISAIT « rebase merge, gatekeeper sealed » — DEUX FAITS FAUX depuis la
              # séparation des rails (revue 2026-08-20). Le merge est signé `chief`, et `rebase`
              # n'est la méthode que sur une PR propre. Un opérateur qui filtrait ses logs sur
              # « gatekeeper » pour auditer les merges croisait ensuite le fil Gitea, y trouvait
              # `system_chief`, et enquêtait sur une contradiction qui n'existait que dans ce texte.
              Logger.info(
                "StepDispatcher: PROMOTE pr=#{ctx.repo}##{pr_number} issue=##{issue_n} " <>
                  "(judges OK → chief merged, gatekeeper promoted + explicit close ; " <>
                  "eng killed, issue lock released)"
              )

            {:error, reason} ->
              Logger.error(
                "StepDispatcher: PROMOTE pr=#{ctx.repo}##{pr_number} issue=##{issue_n} MERGED+SEALED+CLOSED " <>
                  "but issue lock NOT released (#{inspect(reason)}) — residual lcars-in-flight + running " <>
                  "stopwatch on the CLOSED issue, NOT re-polled (open-issue poll skips it) — an incident is " <>
                  "opened on the forge, and the cleanup is MANUAL: no rail reclaims it"
              )

              # « warden/manual cleanup » DESIGNE UN RAIL QUI N'EXISTE PAS, verifie : les deux
              # `warden` du depot portent sur les PODS, aucun ne retire d'etiquette de forge ; et le
              # poller ne lit que `list_open_issues/2`, donc cette issue fermee n'est plus jamais vue.
              # La phrase decrivait donc un rattrapage automatique imaginaire, et « manual » suppose
              # qu'un humain lise ce log — ce que la doctrine D1 refuse pour tout ce qui est
              # load-bearing.
              #
              # L'incident est le seul canal DURABLE qui existe aujourd'hui : une issue sur la forge,
              # que l'operateur voit sans avoir a fouiller les journaux du BEAM. Il ne converge pas
              # tout seul — c'est un appel a la main, et il le dit.
              escalate =
                Keyword.get(
                  ctx.opts,
                  :escalate_fun,
                  &Fleet.Pilot.IncidentRegistry.escalate_gated/5
                )

              _ =
                escalate.(
                  :issue_lock_residual,
                  "#{ctx.repo}##{issue_n}",
                  {:unlock_failed, reason},
                  "issue_lock_residual:#{ctx.repo}##{issue_n}",
                  ctx.forge_opts
                )
          end

          {:ok, {:merged, pr_number}}

        {:error, _} = err ->
          err
      end
    end
  end

  # CI-08 — BOUNDED retry of THE terminal issue unlock (mirror of `MergeAndPromote.{close,set_stage_merged}_with_retry`).
  # This is the LAST reconciliation of the poller-driven promote: after the explicit close, the open-issue poll no
  # longer revisits the issue, so a lost unlock has no natural retry. A transient blip (HTTP 500 / lock contention)
  # self-heals on retry; `unlock` is idempotent (`remove_label` no-ops if absent, `stop_stopwatch` 409 → :ok), so a
  # re-run is safe. Immediate retries (poller tick — a momentary hiccup dominates; no sleep, same stance as the seal
  # retries). NOT propagated (the promote genuinely succeeded — merged + sealed + closed); the caller logs LOUD on
  # persistent failure and keeps `{:ok, {:merged, _}}`.
  @issue_unlock_attempts 3
  defp finalize_issue_unlock(%Ctx{} = ctx, issue_n, producer, attempt \\ 1) do
    case Fleet.Pilot.StepRunCompleter.unlock(
           ctx.forge,
           ctx.repo,
           issue_n,
           ctx.forge_opts,
           producer,
           :delivered
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} when attempt < @issue_unlock_attempts ->
        Logger.warning(
          "StepDispatcher: PROMOTE issue ##{issue_n} unlock attempt " <>
            "#{attempt}/#{@issue_unlock_attempts} FAILED (#{inspect(reason)}) — retrying"
        )

        finalize_issue_unlock(ctx, issue_n, producer, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
