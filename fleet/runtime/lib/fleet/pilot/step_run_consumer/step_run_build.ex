defmodule Fleet.Pilot.StepRunConsumer.StepRunBuild do
  @moduledoc """
  Construction of the **PR-native step_run** from the `pod.completed` event, for
  `Fleet.Pilot.StepRunConsumer`: classifies the role that FINISHES (producer/judge), resolves the
  PR branch, and assembles the `step_run` map that `StepRunCompleter.complete_pr` routes.

  ## Why a separate module

  The consumer orchestrates (Bus → decision → completion); the CONSTRUCTION is
  near-pure data assembly — one input (payload + decided routing), one output
  (the step_run map). A single owned effect: the resolution of a JUDGE's producer
  branch (`list_open_pulls`, the only forge read needed to find the PR to
  review). The caller keeps the execution discipline (E4: `build/5` is called INSIDE
  the offloaded closure — this I/O never blocks the singleton's mailbox).

  ## Producer/judge classification (engineer-first)

    * PRODUCER = `git_native` role (engineer) → pushes the code, opens the PR
      (head = its own branch `feature_branch(n, role)`), carries `deliverable_opts`
      (the SYSTEM verifies + pushes) + its voice `eng_summary`.
    * JUDGE = `payload` role (qualifier/reviewer DOWNSTREAM) → reviews the producer's PR
      (head resolved WITHOUT workflow_map via `parse_feature_branch`), no git deliverable;
      in intent `:reviewed` carries `review_event` (fail-closed verdict) + `review_body`.
    * A judge without a resolvable producer → `producer_branch: nil` → `complete_pr`
      fail-loud `:no_producer_branch` (NEVER a bad merge).

  ## Armored boundary

  `Seams` (narrow struct) carries the only 6 authorized reads — not the consumer's
  state. The producer/judge classification delegates to the single authority
  `GateEngine.producer?/3` (same criterion as the gate decision), preferring the payload's effective
  `deliverable_mode` (C-03) and falling back to the base-role seam.

  **Last revised**: 2026-07-20
  """

  alias Fleet.Pilot.StepRunConsumer.GateEngine
  alias Fleet.Pilot.StepRunConsumer.Verdict

  defmodule Seams do
    @moduledoc """
    Armored boundary of the construction: the ONLY reads `StepRunBuild` may
    perform. Built by the consumer from its DERIVED per-step-run state
    (`repo`/`remote` come from the event, multi-project).
    """
    @enforce_keys [:repo, :remote, :role_emails, :deliverable_mode_fun, :forge_opts]
    defstruct [
      # Repo "owner/name" of the step_run (per-step-run, derived from the event).
      :repo,
      # URL/name of the remote where the system pushes the deliverable (per-step-run).
      :remote,
      # fn role -> [email] — the identity gate verifies the committer's email.
      :role_emails,
      # Resolves a role's deliverable_mode ("git_native" producer / "payload" judge).
      :deliverable_mode_fun,
      # Injectable forge client (nil → Fleet.Pilot.ForgeClient) — judge branch resolution.
      :forge_client,
      # Forge opts (token…) for the judge branch resolution.
      :forge_opts
    ]

    @type t :: %__MODULE__{
            repo: String.t() | nil,
            remote: String.t() | nil,
            role_emails: (String.t() -> [String.t()]),
            deliverable_mode_fun: (String.t() -> {:ok, String.t()} | {:error, term()}),
            forge_client: module() | nil,
            forge_opts: keyword()
          }
  end

  @typedoc """
  Routing decided upstream (GateEngine / apply_verdict): `intent` mandatory;
  `comment_body` (gatekeeper verdict trace) and `judge_target` (brief-review) optional.
  """
  @type route :: %{
          required(:intent) => atom(),
          required(:next_assignee) => String.t() | nil,
          required(:next_step) => String.t() | nil,
          optional(:comment_body) => String.t() | nil,
          optional(:judge_target) => String.t() | nil
        }

  @doc """
  Builds the complete `step_run` map (pr_role classification + deliverable/review/eng_summary)
  for `StepRunCompleter.complete_pr/2`. `next_step` is a transitional bridge:
  workflow_map+next_step engrave the route the StepDispatcher reads to spawn the next
  step. `comment_body` (gatekeeper verdict trace on continue) is carried but not
  yet materialized on the PR — transitional gap noted (the trace lives in the gatekeeper's
  task result; PR-trace = later increment).
  """
  @spec build(map(), pos_integer(), String.t(), route(), Seams.t()) :: map() | {:error, term()}
  def build(payload, n, role, route, %Seams{} = seams) do
    # DR-013: an unloadable cap-profile makes the producer/judge property UNKNOWN → the classification
    # returns `{:error, _}` and the whole build bails out (the caller fails-loud, no step_run completed
    # under an unknown property). Ordered case: `{:error, _}` FIRST (a 2-tuple that would otherwise bind
    # `{pr_role, producer_branch}` and silently corrupt the classification), then the real `{:producer |
    # :judge, branch}`.
    case classify_pr_role(payload, n, role, seams) do
      {:error, _} = err ->
        err

      {pr_role, producer_branch} ->
        build_step_run(payload, n, role, route, seams, pr_role, producer_branch)
    end
  end

  defp build_step_run(payload, n, role, route, seams, pr_role, producer_branch) do
    %{
      repo: seams.repo,
      # pod_id of the PRODUCER (from the pod.completed payload): carries through to the emission of
      # `deliverable.published` (slot-freeze) to address the resident pod to set back to :ready.
      pod_id: payload["pod_id"],
      issue_number: n,
      role: role,
      pr_role: pr_role,
      intent: route.intent,
      next_assignee: route.next_assignee,
      # Transitional bridge: workflow_map_name+next_step engrave the route the StepDispatcher reads
      # to spawn the next step.
      next_step: route.next_step,
      workflow_map: payload["workflow_map"],
      producer_branch: producer_branch,
      base_branch: "main"
    }
    |> put_unless_nil(:comment_body, Map.get(route, :comment_body))
    # judge_target (brief|nil) → complete_judge decides PR-review trace vs issue-comment;
    # absent (normal/gatekeeper path) → default PR behavior (fail-loud if no PR).
    |> put_unless_nil(:judge_target, Map.get(route, :judge_target))
    # Brief provenance: the content-addressed pointer travels via pod.completed → the
    # StepRunCompleter assembles the SLSA triplet `(brief_sha, base_sha, deliverable_sha)` after
    # the publish. Absent (brief not materialized / judge without a brief) → not set.
    |> put_unless_nil(:brief_sha, payload["brief_sha"])
    |> put_unless_nil(:brief_ref, payload["brief_ref"])
    |> maybe_put_deliverable(pr_role, role, payload, n, seams)
    |> maybe_put_review_event(pr_role, route.intent, payload)
    |> maybe_put_eng_summary(pr_role, payload)
  end

  # Classifies the finishing role (engineer-first). Producer = git_native role (engineer) →
  # pushes the code, opens the PR (head = its own branch). Judge = payload role (qualifier/reviewer
  # DOWNSTREAM) → reviews the producer's PR (head = the head.ref of the issue's open PR, resolved
  # without workflow_map via `parse_feature_branch`). A judge without a resolvable producer → `producer_branch`
  # nil → `complete_pr` fail-loud `:no_producer_branch` (never a bad merge). The design steps
  # UPSTREAM of the producer (architect) are out-of-scope (engineer-first decision, PR mapping).
  # DR-013: closed classification — `{:producer,_}` | `{:judge,_}` | `{:error, reason}` (the cap-profile
  # was unloadable → the producer/judge property is UNKNOWN, never a silent judge).
  defp classify_pr_role(payload, n, role, seams) do
    # C-03: prefer the EFFECTIVE deliverable_mode the pod ran with (carried in the payload from the
    # resolved profile at spawn); `nil` (bare/legacy payload) → the seam re-derives from the base role.
    case GateEngine.producer?(role, seams.deliverable_mode_fun, payload["deliverable_mode"]) do
      {:ok, true} ->
        # feature-branch format = single source `Fleet.Pilot.ForgeProtocol.feature_branch/2` (glued to its
        # parser `parse_feature_branch/1`) — no hardcoded `lcars/issue-...` construction here.
        {:producer, Fleet.Pilot.ForgeProtocol.feature_branch(n, role)}

      {:ok, false} ->
        {:judge, judge_producer_branch(payload, n, seams)}

      {:error, _} = err ->
        err
    end
  end

  # Without workflow_map: the producer = the one who OPENED the issue N's PR.
  # Its branch = the `head.ref` of that PR (`lcars/issue-N-<producer>`), found by listing the open PRs
  # + `parse_feature_branch` (same pattern as the Poller). The 1-brick=1-producer model
  # has no workflow_map (without `payload["workflow_map"]`, a workflow_map resolution would return nil → broken
  # merge). No resolvable PR → nil → `complete_pr` fail-loud `:no_producer_branch` (never a
  # bad merge).
  defp judge_producer_branch(_payload, n, seams) do
    forge = seams.forge_client || Fleet.Pilot.ForgeClient

    with {:ok, pulls} <- forge.list_open_pulls(seams.repo, seams.forge_opts),
         head when is_binary(head) <- producer_head_for_issue(pulls, n) do
      head
    else
      _ -> nil
    end
  end

  # The producer branch of issue N = the `head.ref` of the (1st) open PR whose head parses
  # to issue N. Ambiguity (≥2 PRs for N — abnormal) → the first; none → nil (fail-loud downstream).
  defp producer_head_for_issue(pulls, n) do
    Enum.find_value(pulls, fn pr ->
      head = get_in(pr, ["head", "ref"]) || ""

      case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
        {:ok, {^n, _role}} -> head
        _ -> false
      end
    end)
  end

  # The producer (engineer) carries its `deliverable_opts` (publish to its feature-branch); the judge
  # reviews (it doesn't push — its verdict is a native review), no git deliverable.
  defp maybe_put_deliverable(step_run, :producer, role, payload, n, seams),
    do: Map.put(step_run, :deliverable_opts, build_deliverable_opts(role, payload, n, seams))

  defp maybe_put_deliverable(step_run, :judge, _role, _payload, _n, _seams), do: step_run

  # Deliverable of a business step_run: `:git_native`. The pod committed in its workspace,
  # the system verifies (identity/ancestor gate) + pushes. There is NO
  # step with `role: gatekeeper` → no `:payload`/verdict.json branch here (the gatekeeper's
  # verdict is traced by `resume_gate`, not materialized as a step deliverable).
  defp build_deliverable_opts(role, payload, n, seams) do
    %{
      mode: :git_native,
      workspace: payload["workspace"],
      # The ancestor gate is based on `gate_base_sha` (DECONFLICTED from the clone-base):
      # for a rebase resolution, HEAD descends from `main` (the rebase target), not from the old feature
      # tip (rewritten → `base_not_ancestor`). Forward (build/rework): the resolver sets
      # `gate_base_sha == base_sha`. Fallback `base_sha` (bare test payload / spawn predating the field).
      base_sha: payload["gate_base_sha"] || payload["base_sha"],
      allowed_emails: seams.role_emails.(role),
      # The identity gate verifies the trailer `Co-authored-by: LCARS-<role>` (role signature).
      coauthor_role: role,
      remote: seams.remote,
      # feature-branch format = single source `Fleet.Pilot.ForgeProtocol.feature_branch/2` (glued to the parser).
      target_branch: Fleet.Pilot.ForgeProtocol.feature_branch(n, role),
      push?: true,
      local_ref: "HEAD"
    }
  end

  # For a no-workflow_map JUDGE (intent `:reviewed`), the review verdict (APPROVE/REQUEST_CHANGES)
  # is read from the gate-decision returned by the pod (GateBrief: `continue`/`abandon`). We map it here and
  # carry it in the step_run (`:review_event`) → `StepRunCompleter.record_review` posts the corresponding review.
  # `continue`→approve; everything else (`abandon`/redirect/escalate/halt/unreadable)→**request_changes**
  # (fail-closed DECISIVE). NOT `:comment`: a COMMENT review is not decisive → the judge would stay
  # "undecided" and be re-judged in a loop. A non-`continue` verdict = not green
  # → we block the merge (rework), never a merge on a dubious verdict. (gatekeeper-escalation of a
  # non-trivial verdict = backlog; here strict fail-closed.)
  defp maybe_put_review_event(step_run, :judge, :reviewed, payload) do
    result = Verdict.unwrap_worker_envelope(payload["result"] || %{})
    event = Verdict.review_event(Verdict.gate_decision(result))
    step_run = Map.put(step_run, :review_event, event)

    # The judge PRODUCES a `reason`/`details`/`chain` in its gate-decision → we RENDER it on the review
    # (human view + actionable rework). Otherwise `StepRunCompleter.record_review` falls back on the generic
    # body ("the brick does not satisfy its criterion"), unactionable — for the human as for
    # the producer in rework. We set `:review_body` ONLY if there is substance (without
    # which `Map.get(step_run, :review_body, default)` would return `nil` instead of the default).
    case Verdict.judge_review_body(event, result) do
      body when is_binary(body) and body != "" -> Map.put(step_run, :review_body, body)
      _ -> step_run
    end
  end

  defp maybe_put_review_event(step_run, _pr_role, _intent, _payload), do: step_run

  # ENG'S VOICE (OUTGOING info): the PRODUCER may return a markdown `summary` in submit_result
  # (what it did / answer to the review / blocked reason). We extract it from the result (unwrapped from
  # the worker envelope) → `StepRunCompleter` posts it as a PR comment (`as_role` engineer). Coerced by
  # `safe_str` (the eng may return a non-binary → don't crash the singleton). Absent/empty → nothing
  # posted. OUTGOING twin of the INCOMING brief substance — both directions of the pod's
  # information flow carry substance, never bare mechanics.
  defp maybe_put_eng_summary(step_run, :producer, payload) do
    case Verdict.eng_summary(payload) do
      "" -> step_run
      summary -> Map.put(step_run, :eng_summary, summary)
    end
  end

  defp maybe_put_eng_summary(step_run, _pr_role, _payload), do: step_run

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
