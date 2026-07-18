defmodule Fleet.Pilot.BriefBuilder do
  @moduledoc """
  Authority over the FORMAT of briefs: worker / judge / brief-review / rework, plus the
  eng voice instructions. `StepDispatcher` CALLS (it chooses WHICH brief based on the forge state),
  it no longer FORMS the brief itself. (No conflict-resolution brief — merge conflicts are
  ESCALATED to the architect since 2026-07-07, the forge-blind pod cannot rebase.)

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
    [
      "REWORK — une review REQUEST_CHANGES a été déposée sur la PR ##{pr}. Corrige ton code selon le " <>
        "feedback de la review ci-dessous.",
      render_rework_feedback(forge, repo, pr, forge_opts),
      "**Livraison (git-native)** : applique tes corrections dans ton workspace, puis `git add` + `git commit`. " <>
        "Le SYSTÈME pousse ton commit (forge-aveugle, toi tu ne push pas). `submit_result` clôt la tâche : le " <>
        "LIVRABLE = ton COMMIT (ne RE-mets PAS les fichiers dans le payload). Le payload porte ta voix ↓.",
      eng_voice_instruction(:rework),
      Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # ENG VOICE (OUTGOING info, twin of the incoming info starvation): the `summary` rendered in
  # `submit_result` is POSTED on the PR by the system (forge-blind, `as_role` engineer) → the eng
  # has a voice for the human. Without it it is mute on the forge (even an excellent diagnosis would
  # never be seen); verbose, descriptive, traceable feedback.
  defp eng_voice_instruction(:build) do
    "**Ta voix — le `payload` de `submit_result` DOIT contenir un champ `summary`** " <>
      "(ex. `submit_result` avec `payload = {\"summary\": \"Implémenté X ; choisi Y parce que Z\"}`). Le " <>
      "`summary` (markdown COURT) = ce que tu as réalisé + décisions/hypothèses notables. ⚠ ce N'EST PAS du " <>
      "contenu de fichier (ça, c'est ton COMMIT) — c'est ta NARRATION. Le SYSTÈME la poste en commentaire sur " <>
      "la PR : c'est ta SEULE voix pour l'humain qui review. **Si tu es BLOQUÉ** (dépendance/info manquante) " <>
      "et ne peux PAS livrer : NE devine PAS — ajoute `\"blocked\": true` au payload (à côté de `summary` = le " <>
      "motif PRÉCIS, ce qui te manque). Le système ESCALADE à l'humain (aucun commit attendu de toi), jamais un " <>
      "wedge silencieux. Ex. `payload = {\"blocked\": true, \"summary\": \"Manque la spec du protocole X — ...\"}`."
  end

  defp eng_voice_instruction(:rework) do
    "**Ta voix — le `payload` de `submit_result` DOIT contenir un champ `summary`** " <>
      "(ex. `payload = {\"summary\": \"Corrigé le point A en faisant B ; pour le point C, ...\"}`). Le " <>
      "`summary` = COMMENT tu as répondu à CHAQUE point de la review (ce que tu as corrigé). C'est ta " <>
      "NARRATION (pas le code — déjà committé). Le SYSTÈME le poste sur la PR : ta réponse traçable au reviewer."
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
  # name in ring2. `judge` → defused GateBrief; everything else (`worker`, default) → issue body.
  #
  # Returns `{:ok, brief}` | `{:error, {:criterion_unavailable, reason}}`. The error is reachable ONLY on
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
          map()
        ) :: {:ok, String.t()} | {:error, {:criterion_unavailable, term()}}
  def build_brief(
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
        {:ok, build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route)}

      # DELIVERABLE judge: judge_target ABSENT (nil → canonical default) or explicit "deliverable" →
      # judges a deliverable (PR). Already TYPED {:ok, brief} | {:error, {:criterion_unavailable, _}}
      # (F-C083: a read-error on the criterion DEFERS, it never yields a criterion-less judge).
      {"judge", target} when target in [nil, "deliverable"] ->
        build_judge_brief(role, forge, repo, number, forge_opts, route)

      # judge_target PRESENT but outside {brief, deliverable} → anomaly: we don't guess the target.
      {"judge", other} ->
        raise ArgumentError,
              "judge_target #{inspect(other)} out of vocabulary {brief, deliverable} — a judge's target is not inferred"

      {"worker", _} ->
        {:ok, build_worker_brief(role, issue)}

      # kind ∉ {worker, judge} (brief_kind present but out-of-vocab) → fail-loud.
      {other, _} ->
        raise ArgumentError,
              "brief_kind #{inspect(other)} out of vocabulary {worker, judge} — judge-ness is not inferred"
    end
  end

  # Producer brief = the issue's brief + the git-native DELIVERY instruction. Without it,
  # the pod "submits the contents" instead of
  # COMMITTING → the git_native publish finds no commit (`:no_deliverable_commit`).
  # The pod commits LOCALLY; the SYSTEM pushes + opens the PR (forge-blind). The trailer
  # is mandatory (push gate, single source `ForgeIdentity.coauthor_instruction`).
  defp build_worker_brief(role, issue) do
    [
      issue["body"] || "",
      "---",
      "**Livraison (git-native)** : réalise le travail dans ton workspace, puis `git add` + `git commit`. " <>
        "Le SYSTÈME pousse ton commit et ouvre la PR — toi tu ne push pas (forge-aveugle). `submit_result` " <>
        "clôt la tâche : le LIVRABLE = ton COMMIT (ne RE-mets PAS le code/les fichiers dans le payload, ils " <>
        "sont déjà committés). Le payload, lui, N'EST PAS vide : il porte ta voix ↓.",
      eng_voice_instruction(:build),
      Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    ]
    |> Enum.join("\n\n")
  end

  # A **judge** pod must know WHAT
  # to judge AND how to render its verdict. We reuse the canonical brief `Fleet.Workflow.GateBrief`
  # (context + deliverable + question + **`gate-decision-v1.json` contract + canonical options**) — the same
  # as the RAM model. The `result_K` to judge is read from the previous step_run's comment (engraved by
  # StepRunCompleter); the pod stays forge-blind (the runtime reads the comment, no
  # clone).
  defp build_judge_brief(role, forge, repo, number, forge_opts, route) do
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
    # F-C083 — READ-ERROR ≠ ABSENCE. The criterion read can FAIL (forge unreachable/transient). The old
    # `_ -> nil` CONFLATED a read-error with a genuinely-empty body → the judge got the deliverable (diff
    # via `outputs`) with NO criterion → it could approve CRITERION-LESS (false GREEN). We FAIL-CLOSED on a
    # read-error: `{:error, {:criterion_unavailable, reason}}` → the dispatch DEFERS (skip, retry next tick),
    # it NEVER spawns a blind judge. A genuinely-absent body (`{:ok, issue}`, body nil) is a REAL (rare)
    # state → we PROCEED: the judge still has the diff, the empty criterion is the arch's degenerate brief,
    # not a transient failure (a persona judge fail-closes `halt_wait_input` on emptiness, it does not RE-build).
    case forge.get_issue(repo, number, forge_opts) do
      {:ok, issue} ->
        {:ok,
         Fleet.Workflow.GateBrief.build(%{
           step: step,
           workflow_map_id: workflow_map_name,
           gate: nil,
           outputs: outputs,
           request: Map.get(issue, "body")
         })}

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
  defp build_brief_review_brief(role, issue, forge, repo, number, forge_opts, route) do
    # The brief = the ISSUE body, ALREADY in hand (the poller listed the issue; brief-review is
    # always issue-path). We use it → no redundant `get_issue`. Fallback fetch if body absent (robustness).
    brief = issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts)

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

  # Body of the issue ALREADY listed by the poller → used directly; fetch ONLY as a fallback
  # (body absent/empty — defensive; brief-review is always issue-path, the issue is in hand).
  defp issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts) do
    case Map.get(issue, "body") do
      body when is_binary(body) and body != "" ->
        body

      _ ->
        case forge.get_issue(repo, number, forge_opts) do
          {:ok, fetched} -> Map.get(fetched, "body") || ""
          _ -> ""
        end
    end
  end
end
