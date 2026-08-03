defmodule Fleet.Pilot.BriefBuilder do
  @moduledoc """
  Authority over the FORMAT of briefs: worker / judge / brief-review / rework, plus the
  eng voice instructions. `StepDispatcher` CALLS (it chooses WHICH brief based on the forge state),
  it does not FORM the brief itself. (No conflict-resolution brief — merge conflicts are
  ESCALATED to the architect; the forge-blind pod cannot rebase.)

  Judge-ness (and a judge's target) is a SECURITY property: it is NEVER inferred by
  omission of a clause. `build_brief/9` is a TOTAL sum and fail-loud on out-of-vocab `brief_kind`/`judge_target`
  (raise) — a judge must NEVER receive an executable issue body. A judge's brief is
  DEFUSED (`Fleet.Workflow.GateBrief`: `request` rendered as context, not as an executable instruction).

  `forge` is an injected ARG (seam) — never hard-wired. The other deps (`Fleet.CapProfile`,
  `Fleet.Workflow.GateBrief`, `Fleet.Credentials.ForgeIdentity`) are called as-is.

  **Last revised**: 2026-08-03
  """

  require Logger

  # Rework brief: the PRODUCER (engineer) resumes on a REQUEST_CHANGES PR.
  # CARRIES THE SAME git-native instruction as `build_worker_brief` (otherwise `:no_deliverable_commit`: the
  # rework "re-pushes" but the pod is FORGE-BLIND and without the order to COMMIT it delivers nothing —
  # twin of the producer brief). The pod fixes + commits LOCALLY; the SYSTEM pushes (forge
  # boundary). Trailer mandatory (push gate).
  #
  # INFO STARVATION, rework half: without the BODY of the REQUEST_CHANGES reviews,
  # "fix according to the review" is hollow — the forge-blind pod does NOT see the review → it guesses
  # blind (a cautious eng refuses to guess → `blocked_dep` → wedge). We read the feedback on the forge
  # (the runtime, not the pod: forge boundary preserved) and inject it. If the read fails / no body,
  # we fall back to the generic instruction (the pod still has the cloned PR + its code).
  def rework_brief(role, forge, repo, pr, forge_opts, _route, opts \\ []) do
    # The eng-voice prose (OUTGOING info, twin of the incoming info starvation) lives IN the
    # template (F-23): the summary posted on the PR is the producer's only voice for the human.
    Fleet.Workflow.BriefTemplate.render("work-order-rework", %{
      "role" => role,
      "pr" => to_string(pr),
      "feedback_section" =>
        conflict_section(opts) <> render_rework_feedback(forge, repo, pr, forge_opts),
      "signature" => Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    })
  end

  # Conflict-rework lead section (`conflict: true` — Remediation tier 1): the jury APPROVED,
  # main simply moved under the branch (sibling bricks landed). FR: agent-facing work-order
  # prose, same stance as the feedback sections. HONEST about the refs: the pod cannot fetch
  # (forge-blind) — if its workspace's `origin/main` is stale and un-refreshable, the doctrine
  # answer is `blocked`, never a guessed resolution.
  # Two voices for ONE mechanic. The steps are identical (merge, resolve, commit, the system pushes,
  # the jury re-judges); what differs is WHO is being addressed. The producer resumes work it wrote
  # and that the judges approved. The gatekeeper arrives as an exception judge on someone else's
  # branch after the producer's budget ran out — telling it "ton brief est INCHANGÉ" names a brief
  # it never had, and invites it to guess at an intention it does not hold.
  defp conflict_section(opts) do
    case Keyword.get(opts, :conflict, false) do
      false -> ""
      :gatekeeper -> gatekeeper_conflict_section()
      _producer -> producer_conflict_section()
    end
  end

  defp producer_conflict_section do
    """
    ## Conflit de merge à résoudre (prioritaire)

    Ta branche a divergé de `main` : des briques sœurs ont été mergées depuis ta coupe, et le
    merge automatique de ta PR est impossible. Ton brief est INCHANGÉ — le travail livré est
    déjà approuvé par les juges, seul le conflit bloque.

    1. Intègre l'état actuel de main : `git merge origin/main` dans ton workspace.
    2. Résous les conflits en préservant l'intention de TON brief ET le contenu déjà mergé
       des briques sœurs (leur travail est livré : tu composes avec, tu n'écrases pas).
    3. Commite la résolution — le système pousse, les juges re-jugeront le nouveau head.

    Si `origin/main` de ton workspace ne contient PAS les briques sœurs (réf périmée que tu ne
    peux pas rafraîchir — tu n'as pas le réseau), rends `blocked` en le disant : n'invente
    JAMAIS le contenu d'une brique sœur.

    """
  end

  defp gatekeeper_conflict_section do
    """
    ## Passe d'exception : conflit de merge non résolu par le producteur

    Ce n'est PAS ton travail et tu n'as pas de brief à reprendre. Le producteur a épuisé son
    budget de rework sur ce conflit ; tu interviens en dernière passe avant escalade humaine.

    Le contenu des deux côtés est déjà APPROUVÉ : les juges ont validé la branche, et les briques
    sœurs sont mergées sur `main`. Il n'y a donc rien à arbitrer sur le fond — la seule question
    est de composer les deux intentions sans en sacrifier une.

    1. Intègre l'état actuel de main : `git merge origin/main` dans ton workspace.
    2. Résous en PRÉSERVANT les deux apports. Tu n'as pas écrit ce code : tu ne connais pas les
       raisons derrière chaque ligne, donc tu ne choisis pas un camp — tu composes.
    3. Commite la résolution — le système pousse, les juges re-jugeront le nouveau head.

    Rends `blocked` en disant pourquoi dès que la composition demande une DÉCISION que le code ne
    porte pas (deux intentions réellement incompatibles, ou un `origin/main` périmé que tu ne peux
    pas rafraîchir). C'est le résultat attendu d'une passe d'exception qui bute : l'escalade
    humaine existe pour ça, et une résolution devinée coûte plus cher qu'un refus motivé.

    """
  end

  # Renders the feedback of the REQUEST_CHANGES reviews (verdict body of each judge) as an actionable
  # block.
  #
  # F-C083 again, in its OTHER shape. The seam is three-valued (`{:ok, [_|_]} | {:ok, []} |
  # {:error, _}`) and a single `_ -> ""` clause used to collapse the last two: a transient read
  # failure produced the SAME brief as "this PR carries no actionable feedback". The producer then
  # reworks blind while the PR holds detailed REQUEST_CHANGES it never sees — and, believing there
  # was nothing to address, it plausibly ships the same defect and burns another review cycle.
  #
  # The remedy is NOT fail-closed here, and the asymmetry with `judge_outputs/4` is the point: a
  # judge given the wrong matter renders a WRONG VERDICT, so it must never run; a producer without
  # its feedback merely works WORSE. Deferring every rework on a transient forge hiccup would wedge
  # the rail to avoid a degradation. So we proceed — and we make the gap VISIBLE on both sides: a
  # warning on the operator rail, and a line in the brief itself, because the pod cannot read our
  # logs and an unexplained absence is exactly what made this defect silent.
  defp render_rework_feedback(forge, repo, pr, forge_opts) do
    case forge.change_request_feedback(repo, pr, forge_opts) do
      {:ok, [_ | _] = feedbacks} ->
        sections =
          Enum.map_join(feedbacks, "\n\n", fn fb ->
            "### Review de `#{fb["login"]}`\n#{fb["body"]}"
          end)

        "## Feedback de review à traiter (REQUEST_CHANGES)\n\n#{sections}"

      {:ok, []} ->
        ""

      {:error, reason} ->
        # Rail prefix = the FACADE this module was extracted from (StepDispatcher), not its own
        # last segment: extracting a cluster must never fragment the trace an operator greps.
        Logger.warning(
          "StepDispatcher: rework feedback UNREADABLE repo=#{repo} pr=#{pr} " <>
            "reason=#{inspect(reason)} — the producer reworks without the reviews (degraded, not deferred)"
        )

        "## Feedback de review — NON LU\n\n" <>
          "Les reviews REQUEST_CHANGES de cette PR n'ont pas pu être lues sur la forge " <>
          "(erreur transitoire). Elles EXISTENT : cette PR a été retoquée. Lis-les toi-même sur " <>
          "la PR avant de corriger — ne suppose pas qu'il n'y avait rien à traiter."
    end
  end

  # The shape of the brief is a property of the role (cap-profile `brief_kind`), NOT a magic
  # role name. `judge` → defused GateBrief; everything else (`worker`, default) → issue body.
  #
  # Returns `{:ok, brief, kind}` (`kind` = the EFFECTIVE `"worker" | "judge"` — step override
  # resolved, so the caller routes the physical object without re-deriving judge-ness) |
  # `{:error, {:criterion_unavailable, reason}}`. The error is reachable ONLY on
  # the DELIVERABLE-judge path, when the criterion (issue body) can't be READ from the forge (F-C083:
  # read-error ≠ absence → the dispatch DEFERS rather than spawn a criterion-less judge). Out-of-vocab
  # `brief_kind`/`judge_target` still `raise` (structural config bug, fail-loud).
  @spec build_brief(
          Fleet.CapProfile.t(),
          String.t(),
          module(),
          String.t(),
          integer(),
          map(),
          keyword(),
          {String.t(), String.t()} | term(),
          map(),
          keyword()
        ) :: {:ok, String.t(), String.t()} | {:error, {:criterion_unavailable, term()}}
  def build_brief(
        profile,
        role,
        forge,
        repo,
        number,
        issue,
        forge_opts,
        route,
        step_spec,
        opts \\ []
      ) do
    # POINTER resolution FIRST (E4): a consequential brief lives as a doc committed in
    # work/ops; the ticket body then carries summary + `Brief: <ref> @ <commit>` (composed by
    # the delegation tool, notation in Fleet.Layout). Resolved HERE, once, for every path
    # (worker order, brief judge, deliverable-judge criterion): the pinned doc BECOMES the
    # brief downstream. Unresolvable pointer → DEFER (`:criterion_unavailable` — the existing
    # rail; never a guessed brief). `:none` → the body IS the brief (inline PoC path, both
    # channels honest, same downstream).
    with {:ok, issue} <- resolve_issue_brief(issue, repo, opts) do
      do_build_brief(
        profile,
        role,
        forge,
        repo,
        number,
        issue,
        forge_opts,
        route,
        step_spec,
        opts
      )
    end
  end

  defp do_build_brief(
         profile,
         role,
         forge,
         repo,
         number,
         issue,
         forge_opts,
         route,
         step_spec,
         opts
       ) do
    # The STEP's `brief_kind` (workflow_map) TAKES PRECEDENCE over the profile's (per-step override) — it
    # drives a worker profile as a JUDGE for one step without duplicating the profile. NO canon role uses
    # it today: `scoper` was its only user and became a NATIVE judge at the 2026-07-30 split (the override
    # described a dual nature it never had). The mechanism stays because it is the generic way to answer
    # "this step judges", and removing it would force a duplicate profile the day one is needed.
    # ABSENT at the step → profile default
    # (itself "worker" by default, fail-safe) via the `||`: absence is NOT an anomaly. What
    # follows handles the PRESENT-but-out-of-vocab value, distinct from absence.
    kind = Map.get(step_spec, "brief_kind") || Fleet.CapProfile.brief_kind(profile)

    # TOTAL sum and fail-loud. Judge-ness (and a judge's target) is a
    # SECURITY property: it is NEVER inferred by omission of a clause. An out-of-vocab kind/target (typo, or
    # value from a future vocabulary) MUST NOT silently fall back to worker — otherwise a judge
    # role would receive an EXECUTABLE issue body (active brief) instead of a defused brief. We
    # reject loudly (raise) rather than build a dangerous brief silently.
    case {kind, Map.get(step_spec, "judge_target")} do
      # BRIEF judge (judge_target:brief) → judges the issue.body (executable?), NOT a deliverable
      # (no code upstream). The brief is in hand (poller-listed) → no criterion read-error path.
      {"judge", "brief"} ->
        {:ok, build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route, opts),
         "judge"}

      # DELIVERABLE judge: judge_target ABSENT (nil → canonical default) or explicit "deliverable" →
      # judges a deliverable (PR). Already TYPED {:ok, brief} | {:error, {:criterion_unavailable, _}}
      # (F-C083: a read-error on the criterion DEFERS, it never yields a criterion-less judge).
      {"judge", target} when target in [nil, "deliverable"] ->
        with {:ok, brief} <- build_judge_brief(role, forge, repo, number, forge_opts, route, opts) do
          {:ok, brief, "judge"}
        end

      # judge_target PRESENT but outside {brief, deliverable} → anomaly: we don't guess the target.
      {"judge", other} ->
        raise ArgumentError,
              "judge_target #{inspect(other)} out of vocabulary {brief, deliverable} — a judge's target is not inferred"

      {"worker", _} ->
        {:ok, build_worker_brief(role, issue), "worker"}

      # kind ∉ {worker, judge} (brief_kind present but out-of-vocab) → fail-loud.
      {other, _} ->
        raise ArgumentError,
              "brief_kind #{inspect(other)} out of vocabulary {worker, judge} — judge-ness is not inferred"
    end
  end

  # Producer brief = a structured WORK ORDER document (template `work-order-build`, F-23/E1:
  # same visual family as the gate-briefs — the prose lives in priv, the code fills slots):
  # the issue's brief + the git-native DELIVERY instruction. Without the delivery contract,
  # the pod "submits the contents" instead of COMMITTING → the git_native publish finds no
  # commit (`:no_deliverable_commit`). The pod commits LOCALLY; the SYSTEM pushes + opens the
  # PR (forge-blind). The trailer is mandatory (push gate, single source
  # `ForgeIdentity.coauthor_instruction` — the {{signature}} slot).
  defp build_worker_brief(role, issue) do
    Fleet.Workflow.BriefTemplate.render("work-order-build", %{
      "role" => role,
      "issue" => to_string(issue["number"] || "?"),
      "brief_body" => issue["body"] || "",
      "brief_source" => brief_source_line(issue),
      "signature" => Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    })
  end

  # F-25 — the order CITES its source: a pointer-resolved brief names the authored doc
  # (`ref @ commit`, the walkable link into work/ops history); an inline brief says so
  # honestly (never a fabricated citation). FR: rendered to the human eye via the forge.
  defp brief_source_line(%{"_brief_source" => {ref, sha}}),
    do: "`#{ref} @ #{sha}` (doc d'auteur commité dans work/ops — version pinnée ci-dessus)"

  defp brief_source_line(_issue), do: "brief inline du ticket (pas de doc d'auteur séparé)"

  # A **judge** pod must know WHAT
  # to judge AND how to render its verdict. We reuse the canonical brief `Fleet.Workflow.GateBrief`
  # (context + deliverable + question + **`gate-decision-v1.json` contract + canonical
  # options**). The `result_K` to judge is read from the previous step_run's comment (engraved by
  # StepRunCompleter); the pod stays forge-blind (the runtime reads the comment, no
  # clone).
  # The brief-pointer resolution (E4) applied to a ticket body: `:none` → body unchanged
  # (inline brief); a well-formed pointer → the PINNED doc replaces the body (the doc IS the
  # brief — summary stays human-facing on the forge); unresolvable/invalid → DEFER via the
  # criterion rail (the pointer can lie, git cannot; never a guessed brief).
  defp resolve_issue_brief(issue, repo, opts) do
    case Fleet.Layout.parse_brief_pointer(issue["body"]) do
      :none ->
        {:ok, issue}

      {:ok, {ref, sha}} ->
        case Fleet.Workflow.BriefArtifact.resolve(
               repo,
               ref,
               sha,
               Keyword.take(opts, [:work_root])
             ) do
          # F-25 — the resolved pointer is KEPT alongside the pinned content: the work order
          # cites its source doc (`ref @ commit`) instead of consuming the link silently.
          {:ok, content} ->
            {:ok, issue |> Map.put("body", content) |> Map.put("_brief_source", {ref, sha})}

          {:error, reason} ->
            {:error, {:criterion_unavailable, {:brief_pointer, reason}}}
        end

      {:error, reason} ->
        {:error, {:criterion_unavailable, {:brief_pointer, reason}}}
    end
  end

  defp build_judge_brief(role, forge, repo, number, forge_opts, route, opts) do
    with {:ok, outputs} <- judge_outputs(forge, repo, number, forge_opts) do
      step_judge_brief(role, forge, repo, number, forge_opts, route, opts, outputs)
    end
  end

  # F-C083 — READ-ERROR ≠ ABSENCE, applied to the PREDECESSOR read. The rule is stated 35 lines
  # below for the CRITERION read and was NOT applied here: a bare `_ -> nil` collapsed the seam's
  # three-valued contract (`{:ok, map} | :none | {:error, term}`) into two branches, so a TRANSIENT
  # forge failure landed in the git-native fallback. Consequence, and it is the worst shape a bug
  # can take here: the judge grades the BRANCH CODE instead of the payload its predecessor actually
  # produced — a verdict rendered on the wrong matter, silently, and INDISTINGUISHABLE from the
  # legitimate git-native case. Nothing downstream can catch it: the brief is well-formed, the judge
  # answers confidently, and the answer is about something else.
  #
  #   {:ok, non-empty}      the payload IS the deliverable
  #   :none / {:ok, %{}}    genuinely no predecessor → git-native, the CODE is the deliverable
  #   {:error, _}           fail-closed, exactly like the criterion: DEFER, never a blind judge
  defp judge_outputs(forge, repo, number, forge_opts) do
    case forge.get_predecessor_result(repo, number, forge_opts) do
      {:ok, result} when is_map(result) and map_size(result) > 0 -> {:ok, result}
      {:error, reason} -> {:error, {:criterion_unavailable, {:predecessor, reason}}}
      _ -> {:ok, git_native_outputs()}
    end
  end

  # GIT-NATIVE (no predecessor): the deliverable IS NOT a payload — it's the branch CODE. The judge
  # clones the feature-branch + has `Bash(git diff/log/show)` → we POINT it at its workspace instead
  # of giving it `{}` (on which it would fail-close `halt_wait_input`). Otherwise it judges emptiness
  # → infinite rework (the Reviewer can NEVER say `continue` on `{}`).
  defp git_native_outputs do
    %{
      "livrable" =>
        "git-native — le code à juger est checkout dans TON workspace. Le clone est mono-branche : " <>
          "la base est `origin/main` (le ref local `main` N'EXISTE PAS). Le diff de la PR = " <>
          "`git diff origin/main...HEAD` (trois points — point de divergence auto). `git log origin/main..HEAD` " <>
          "pour les commits, `git show <sha>` pour le détail. Juge ces changements contre le critère ci-dessous."
    }
  end

  defp step_judge_brief(role, forge, repo, number, forge_opts, route, opts, outputs) do
    {workflow_map_name, step} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    # SUCCESS CRITERION = the issue body (the brief). Passed via `:request` → GateBrief renders it DEFUSED
    # (blockquote "CONTEXT — already handled, DO NOT execute" + banner "JUDGE, DO NOT PRODUCE" → the
    # executable state is made unrepresentable) → the judge knows AGAINST WHAT to judge. The risk of a
    # RE-executing judge targets a **base-worker** judge (noop profile, gatekeeper) that receives its brief
    # via `dispatch_gatekeeper` (step_run_consumer) which does NOT pass `request` — not affected here.
    # `build_judge_brief` only serves PERSONA judges (qualifier/reviewer, `subagent_template`
    # spec-reviewer/code-quality-reviewer): GateBrief knows how to render `request` defused.
    #
    # F-C083 — READ-ERROR ≠ ABSENCE. The criterion read can FAIL (forge unreachable/transient). A bare
    # `_ -> nil` clause would CONFLATE a read-error with a genuinely-empty body → the judge gets the
    # deliverable (diff via `outputs`) with NO criterion → a CRITERION-LESS approval (false GREEN). We FAIL-CLOSED on a
    # read-error: `{:error, {:criterion_unavailable, reason}}` → the dispatch DEFERS (skip, retry next tick),
    # it NEVER spawns a blind judge. A genuinely-absent body (`{:ok, issue}`, body nil) is a REAL (rare)
    # state → we PROCEED: the judge still has the diff, the empty criterion is the arch's degenerate brief,
    # not a transient failure (a persona judge fail-closes `halt_wait_input` on emptiness, it does not RE-build).
    case forge.get_issue(repo, number, forge_opts) do
      {:ok, issue} ->
        # The criterion goes through the SAME pointer resolution as the dispatch entry (E4):
        # a pointer-ticket's criterion is the PINNED doc, never the pointer line itself.
        with {:ok, issue} <- resolve_issue_brief(issue, repo, opts) do
          {:ok,
           Fleet.Workflow.GateBrief.build(%{
             step: step,
             workflow_map_id: workflow_map_name,
             gate: nil,
             outputs: outputs,
             request: Map.get(issue, "body")
           })}
        end

      {:error, reason} ->
        {:error, {:criterion_unavailable, reason}}
    end
  end

  # Brief of a BRIEF judge (brief-review, judge_target:brief). The scoper judges the BRIEF
  # (issue.body written by the arch) BEFORE the engineer sets off: executable without a new question? We
  # reuse the SAME GateBrief (gate-decision-v1 contract + canonical options) as the other judges — only
  # `subject: :brief` reframes the "thing to judge". The BRIEF goes into `outputs` (the thing TO JUDGE; ≠
  # build_judge_brief where outputs = the deliverable/code); no `request` (the executability criterion is
  # carried by the :brief framing). The judge is PRE-PR (no clone, no deliverable) → N0-consistent.
  defp build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route, opts) do
    # The brief = the ISSUE body, ALREADY in hand AND already pointer-resolved (the entry
    # resolution of `build_brief`). Fallback fetch if body absent (robustness) — the fetched
    # body gets the same resolution, best-effort.
    brief = issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts, opts)

    {workflow_map_name, step} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    # DEDUP (user 2026-07-19): a pointer-backed brief is NOT re-embedded — the gate-brief points
    # at the SOURCE doc (`_brief_source` = {ref, sha}, kept by the F-25 resolution) and the judge
    # reads it through its RO project work/ops mount (`project_ops_mount`: "a judge needs it to
    # weigh completeness" — the mount is already there). Before this, gate-briefs/issue-N-<judge>.md
    # duplicated briefs/<slug>.md verbatim in the same worktree. Inline brief (degraded dispatch,
    # no authored doc) → embedded as before, nothing else to point at.
    outputs =
      case Map.get(issue, "_brief_source") do
        {ref, sha} -> %{"brief_ref" => ref, "brief_sha" => sha}
        _ -> %{"brief" => brief}
      end

    Fleet.Workflow.GateBrief.build(%{
      step: step,
      workflow_map_id: workflow_map_name,
      gate: nil,
      subject: :brief,
      outputs: outputs
    })
  end

  # Body of the issue ALREADY listed by the poller → used directly (pointer-resolved at the
  # `build_brief` entry); fetch ONLY as a fallback (body absent/empty — defensive). The
  # FETCHED body gets the pointer resolution too, best-effort: an unresolvable pointer here
  # degrades to "" (the existing degenerate-empty path — the persona judge fail-closes
  # `halt_wait_input`, never judges the pointer line as prose).
  defp issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts, opts) do
    case Map.get(issue, "body") do
      body when is_binary(body) and body != "" ->
        body

      _ ->
        with {:ok, fetched} <- forge.get_issue(repo, number, forge_opts),
             {:ok, resolved} <- resolve_issue_brief(fetched, repo, opts) do
          Map.get(resolved, "body") || ""
        else
          _ -> ""
        end
    end
  end
end
