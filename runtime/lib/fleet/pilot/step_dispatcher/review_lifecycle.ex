defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle do
  @moduledoc """
  REVIEW (PR) lifecycle of `Fleet.Pilot.StepDispatcher`.

  `StepDispatcher.dispatch_review/2` (PUBLIC — the poller's contract) stays at the core: it does the PR
  gate (`in-flight`/`awaits-arch`), reads `pr_review_state` (commit-scoped verdicts + stable jury) THEN
  DELEGATES all routing here. This module carries the ROUTING (`dispatch_by_verdicts/6`) + the sealed
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
  alias Fleet.Pilot.StepDispatcher.ArchEscalation
  alias Fleet.Pilot.StepDispatcher.Spawn
  alias Fleet.Project.Roles

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
            # Injected workflow_map loader (seam `:workflow_map_loader`, default `&Fleet.Workflow.Loader.load!/2`) —
            # reads the map-level rework budget (`spec.max_rework_rounds`) on the PR rework path.
            # The four forms `WorkflowMapNav.safe_load/3` serves: the rail's default is the binary
            # capture, the Poller threads a MODULE, the stubs are unary.
            workflow_map_loader:
              (String.t(), keyword() -> map()) | (String.t() -> map()) | module(),
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

    @doc false
    # Boundary contract of the escalation writing: every decider (Remediation, the conflict
    # ladder, VerdictException, the promotion) hands `ArchEscalation` ONLY its three forge seams
    # (`@enforce_keys` → an out-of-3-seams access does not compile), never the whole context —
    # and builds them HERE, the one site.
    @spec arch_seams(t()) :: Fleet.Pilot.StepDispatcher.ArchEscalation.Seams.t()
    def arch_seams(%__MODULE__{} = ctx) do
      %Fleet.Pilot.StepDispatcher.ArchEscalation.Seams{
        forge: ctx.forge,
        repo: ctx.repo,
        forge_opts: ctx.forge_opts
      }
    end

    @doc false
    # The rework budget of the issue's ENGRAVED card (`spec.max_rework_rounds`), read under the
    # repo's own catalogue — the same number bounds the judge rework and the conflict rework.
    @spec rework_budget(t(), integer()) :: {:ok, integer()} | {:error, term()}
    def rework_budget(%__MODULE__{} = ctx, issue_n) do
      with {:ok, {map_name, _step}} when is_binary(map_name) <-
             Fleet.Pilot.StepDispatcher.Spawn.route_for(
               ctx.forge,
               ctx.repo,
               issue_n,
               ctx.forge_opts
             ),
           {:ok, workflow_map} <-
             Fleet.Pilot.WorkflowMapNav.safe_load(
               ctx.workflow_map_loader,
               map_name,
               Fleet.Workflow.Loader.card_opts_for_repo(ctx.repo)
             ) do
        {:ok, Map.fetch!(workflow_map, "max_rework_rounds")}
      else
        # The specs of route_for/4 (typed direct call) and safe_load cover every shape —
        # a catch-all `other ->` clause here would be dead-by-spec (dialyzer-provable).
        {:ok, nil} -> {:error, :routeless}
        {:error, _} = err -> err
      end
    end
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
    # THE FULL ARITY, and naming the `/2` here would be wrong: it cannot return `:gray_zone` at
    # all (the behaviour's contract says so, and Dialyzer holds it), so a reader following such a
    # comment goes looking for the gray zone in a function structurally incapable of producing one
    # — a text describing a neighbouring behaviour rather than the one under it.
    case Fleet.Forge.Client.Jury.review_outcome(
           requested,
           verdicts,
           findings,
           issue_card_verdict_policy(head, ctx),
           Roles.gatekeeper_role(ctx.opts)
         ) do
      {:pending, [next | _]} ->
        # THE BRANCH IS PARSED BEFORE THE GATE, and the order carries weight. A PR whose head is
        # not a fleet feature branch can never receive a judge — `RoleDispatch.dispatch` refuses it
        # on this very parse — so paying two forge reads, and possibly a bounded CI wait ending in
        # an escalation, to reach a conclusion already in hand is pure spend — and an unparseable
        # head would otherwise make `issue_card_ci/2` answer `:ignore`, short-circuiting the gate
        # for the wrong reason.
        with {:ok, _} <- RoleDispatch.parse_feature_branch_or_skip(head) do
          gate_then_dispatch(pr_number, head, next, ctx)
        end

      :no_jury ->
        # The CARD arbitrates (doc point 4): zero-judge card → this IS the nominal path, seal
        # directly; judged card → orphan PR, lay the card's jury (adoption). The arbitrating card
        # is THE ISSUE'S ENGRAVED one when a route exists (`wfmap/*` — an workshop-direct issue's
        # zero-judge choice is deliberate); the project's declared card only for a true orphan
        # (no route). Reading the project card unconditionally re-adopts its judges onto an ops PR
        # every tick (measured, faceproof bench).
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
      # pouvoir distinguer « la passe a échoué » de « la passe n'existe pas sur ce conteneur ».
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

  # THE CI IS A PRE-CONDITION OF THE SUMMONS, not an afterthought at merge time. Without this gate
  # the machine rail and the judgement rail never meet: judges are spawned on code nobody has built,
  # and the red surfaces at the PROMOTE, after the tokens are spent. `CiGate` decides (the CARD
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

      # A TERMINAL state, not a transient one: the deterministic wall found the statement lying
      # about the brick, and no tick will change that. A bare `{:error, _}` reaches the poller as
      # `:keep` (no label, the same seal every tick, the ⛔ comment deduplicated), so it is
      # escalated: `lcars-awaits-arch`, which `dispatch_review` skips on, and the cause named to
      # the one person who can act (2026-09-05).
      {:error, {:provenance_incoherent, reason}} ->
        ArchEscalation.escalate_merge_blocked(
          Ctx.arch_seams(ctx),
          pr_number,
          head,
          :provenance_incoherent,
          reason
        )

      other ->
        other
    end
  end

  # THE ISSUE'S ENGRAVED CARD, resolved ONCE for every reader of it (the jury and the CI policy):
  # the head names the issue, the issue's route names the card, the repo names the catalogue the
  # card is read in. `:project` when any link is missing — a human PR, an adopted orphan, a route
  # not yet engraved — and every reader then falls back to the PROJECT's declared card, the same
  # one. Two readers with two resolutions is how a PR came to be judged under the project's jury
  # and under NO CI policy (the divergence is invisible: each fallback is coherent alone).
  defp issue_card(head, %Ctx{} = ctx) do
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
      {:ok, map}
    else
      _ -> :project
    end
  end

  # The engraved card's jury, else the project card's. Same fallback shape as the completer's
  # `step_run_jury` twin.
  defp issue_card_jury(head, %Ctx{} = ctx) do
    case issue_card(head, ctx) do
      # Through Roles.jury/2 (not the raw key): the reviewer_roles injection seam keeps priority.
      {:ok, %{"jury" => jury} = map} when is_list(jury) -> Roles.jury(map, ctx.opts)
      _ -> Roles.project_jury(ctx.repo, ctx.opts)
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
        Roles.verdict_policy_for(
          ctx.forge,
          ctx.repo,
          issue_n,
          Keyword.put(ctx.opts, :forge_opts, ctx.forge_opts)
        )

      # A head that is not a fleet feature branch has no engraved route to read. The project's own
      # card still governs it — same fallback as the jury and the CI policy, for the same PRs
      # (human PR, adopted orphan).
      _ ->
        Roles.project_verdict_policy(ctx.repo, ctx.opts)
    end
  end

  # The card's CI policy, read off the SAME resolution as its jury (`issue_card/2`): the engraved
  # card when a route exists, the project's declared card otherwise — one card for the trio.
  #
  # PUBLIC exprès : la propriete qui compte n'est ni « le champ traverse le loader » ni « la porte
  # gate sur la valeur », toutes deux tenues ailleurs — c'est leur JOINTURE, et elle n'est
  # observable que d'ici. Les valeurs de l'enum, elles, vivent en UN seul site, pour qu'un renommage
  # n'ait qu'un endroit ou echouer.
  @doc false
  @spec issue_card_ci(String.t(), Ctx.t()) :: :required | :ignore
  def issue_card_ci(head, %Ctx{} = ctx) do
    case issue_card(head, ctx) do
      {:ok, map} -> Roles.ci(map)
      :project -> Roles.project_ci(ctx.repo, ctx.opts)
    end
  end

  @doc false
  # The jury the same way, PUBLIC for the witness that proves the two readers AGREE — on the
  # engraved card and on the fallback.
  @spec issue_card_jury_of(String.t(), Ctx.t()) :: [String.t()]
  def issue_card_jury_of(head, %Ctx{} = ctx), do: issue_card_jury(head, ctx)

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

  # PROMOTION pilotee par l'etat de la PR : tous les juges ont approuve, le pipeline SORT.
  #
  # Le commentaire de sceau est HONNETE — on ne ment pas, on montre : livre par l'ingenieur, AVIS
  # FAVORABLE des juges, merge par le SYSTEME. C'est LCARS qui agrege les avis, pas la forge, et le
  # dire explicitement est ce qui empeche de lire une protection de branche la ou il n'y en a pas.
  #
  # L'issue est fermee EXPLICITEMENT et APRES le commentaire, jamais par une auto-fermeture de la
  # forge : chronologie coherente. Pas de verrou ici — le poller est mono-processus — et une PR deja
  # mergee rend un 409, donc elle disparait au tick suivant : idempotent.
  #
  # Le sceau lui-meme (commentaire, signataire, merge) vit dans UNE autorite partagee, jamais forkee.
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
             [
               head_branch: head,
               # The PR's own base, read at the dispatch_review single site (face-projet):
               # the seal aligns the FACE worktree the merge landed on.
               base_branch: Keyword.fetch!(ctx.opts, :pr_base_branch)
               # The faces the provenance wall reads are the ones this dispatch reads
               # (`Roles.project_*` take `:code_root` from the same opts): absent, the seal's
               # own defaults apply, exactly as before.
             ] ++ Keyword.take(ctx.opts, [:code_root, :ops_root])
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
          # (Easy to miss: the completer's promote carries it, while the poller promote — the path
          # real rounds actually take — is the one that must not say "étape franchie".)
          #
          # ⚠ NE PAS ANNONCER LE RETRAIT AVANT SON VERDICT. L'issue vient d'etre FERMEE, donc le
          # balayage des issues ouvertes ne repassera plus : un unlock perdu laisse un verrou
          # residuel et un chronometre qui court, SANS aucune reprise naturelle. C'est la DERNIERE
          # occasion de reconcilier — d'ou un verdict verifie, une reprise bornee (l'unlock etant
          # idempotent) et un journal conforme au resultat REEL, jamais un « verrou libere » pose
          # d'avance qui mentirait sur un echec.
          #
          # ⚠ ET L'UNLOCK N'EST PAS FONDU DANS LE SCEAU : il appartient a une autre autorite, et
          # l'IDENTITE qui arrete le chronometre DIFFERE selon l'appelant. Les fondre coupleraient le
          # sceau au cycle de vie du verrou ET forkeraient cette identite. Ce qui converge est la
          # discipline — verifier puis annoncer — pas les deux gestes.
          case finalize_issue_unlock(ctx, issue_n, producer) do
            :ok ->
              # ⚠ CE LOG NE DIT NI « rebase » NI « gatekeeper sealed » : le merge est signé
              # `chief`, et `rebase` n'est la méthode que sur une PR propre. Un opérateur qui
              # filtre ses logs sur « gatekeeper » pour auditer les merges croiserait ensuite le
              # fil Gitea, y trouverait `system_chief`, et enquêterait sur une contradiction qui
              # n'existerait que dans ce texte.
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

              # AUCUN RAIL NE RECLAME CE VERROU : les deux `warden` du depot portent sur les PODS,
              # aucun ne retire d'etiquette de forge ; et le poller ne lit que `list_open_issues/2`,
              # donc cette issue fermee n'est plus jamais vue. Un log qui promettrait un rattrapage
              # automatique mentirait, et « manual » suppose qu'un humain le lise — ce que la
              # doctrine D1 refuse pour tout ce qui est load-bearing.
              #
              # L'incident est le seul canal DURABLE qui existe : une issue sur la forge,
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

  # CI-08 — BOUNDED retry of THE terminal issue unlock (mirror of
  # `MergeAndPromote.{close,set_stage_merged}_with_retry`). This is the LAST reconciliation of the poller-driven
  # promote: after the explicit close, the open-issue poll no longer revisits the issue, so a lost unlock has no natural
  # retry. A transient blip (HTTP 500 / lock contention) self-heals on retry; `unlock` is idempotent (`remove_label`
  # no-ops if absent, `stop_stopwatch` 409 → :ok), so a re-run is safe. Immediate retries (poller tick — a momentary
  # hiccup dominates; no sleep, same stance as the seal retries). NOT propagated (the promote genuinely succeeded —
  # merged + sealed + closed); the caller logs LOUD on persistent failure and keeps `{:ok, {:merged, _}}`.
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
