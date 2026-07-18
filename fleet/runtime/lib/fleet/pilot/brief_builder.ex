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

  **Last revised**: 2026-07-18
  """

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
  def rework_brief(role, forge, repo, pr, forge_opts, _route) do
    # The eng-voice prose (OUTGOING info, twin of the incoming info starvation) lives IN the
    # template (F-23): the summary posted on the PR is the producer's only voice for the human.
    Fleet.Workflow.BriefTemplate.render("work-order-rework", %{
      "role" => role,
      "pr" => to_string(pr),
      "feedback_section" => render_rework_feedback(forge, repo, pr, forge_opts),
      "signature" => Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    })
  end

  # Renders the feedback of the REQUEST_CHANGES reviews (verdict body of each judge) as an actionable block.
  # `""` if nothing (read failed or no body) → the brief falls back to the generic instruction (Enum.reject).
  defp render_rework_feedback(forge, repo, pr, forge_opts) do
    case forge.change_request_feedback(repo, pr, forge_opts) do
      {:ok, [_ | _] = feedbacks} ->
        sections =
          Enum.map_join(feedbacks, "\n\n", fn fb ->
            "### Review de `#{fb["login"]}`\n#{fb["body"]}"
          end)

        "## Feedback de review à traiter (REQUEST_CHANGES)\n\n#{sections}"

      _ ->
        ""
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
      do_build_brief(profile, role, forge, repo, number, issue, forge_opts, route, step_spec, opts)
    end
  end

  defp do_build_brief(profile, role, forge, repo, number, issue, forge_opts, route, step_spec, opts) do
    # The STEP's `brief_kind` (workflow_map) TAKES PRECEDENCE over the profile's (per-step override) — reuses
    # a worker (consultant) profile as a JUDGE without a duplicate profile. ABSENT at the step → profile default
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
        {:ok, build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route, opts), "judge"}

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
      "signature" => Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    })
  end

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
        case Fleet.Workflow.BriefArtifact.resolve(repo, ref, sha, Keyword.take(opts, [:work_root])) do
          {:ok, content} -> {:ok, Map.put(issue, "body", content)}
          {:error, reason} -> {:error, {:criterion_unavailable, {:brief_pointer, reason}}}
        end

      {:error, reason} ->
        {:error, {:criterion_unavailable, {:brief_pointer, reason}}}
    end
  end

  defp build_judge_brief(role, forge, repo, number, forge_opts, route, opts) do
    predecessor =
      case forge.get_predecessor_result(repo, number, forge_opts) do
        {:ok, result} when is_map(result) and map_size(result) > 0 -> result
        _ -> nil
      end

    # GIT-NATIVE (empty predecessor): the deliverable IS NOT a payload — it's the branch
    # CODE. The judge clones the feature-branch + has `Bash(git diff/log/show)` → we POINT it at its
    # workspace instead of giving it `{}` (on which it would fail-close `halt_wait_input`). Otherwise it judges
    # emptiness → infinite rework (the Reviewer can NEVER say `continue` on `{}`).
    outputs =
      predecessor ||
        %{
          "livrable" =>
            "git-native — le code à juger est checkout dans TON workspace. Le clone est mono-branche : " <>
              "la base est `origin/main` (le ref local `main` N'EXISTE PAS). Le diff de la PR = " <>
              "`git diff origin/main...HEAD` (trois points — point de divergence auto). `git log origin/main..HEAD` " <>
              "pour les commits, `git show <sha>` pour le détail. Juge ces changements contre le critère ci-dessous."
        }

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

  # Brief of a BRIEF judge (brief-review, judge_target:brief). The consultant judges the BRIEF
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

    Fleet.Workflow.GateBrief.build(%{
      step: step,
      workflow_map_id: workflow_map_name,
      gate: nil,
      subject: :brief,
      outputs: %{"brief" => brief}
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
