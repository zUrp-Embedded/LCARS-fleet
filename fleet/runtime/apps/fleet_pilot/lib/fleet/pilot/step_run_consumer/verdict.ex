defmodule Fleet.Pilot.StepRunConsumer.Verdict do
  @moduledoc """
  PURE step-run verdict cluster: **decoding** (reading the gate-decision-v1 decision
  buried in the TaskQueue/worker envelopes) + **text rendering** (readable verdict trace,
  review body, eng voice) extracted from `Fleet.Pilot.StepRunConsumer`.

  No function here carries `state`: they operate on the raw payload/result of an event
  (`pod.completed` / `work_item.completed`) and return a decision string or forge text. The
  stateful decision core (`apply_verdict`, `resume_gate`, `complete_business_step_run`… — `gate_decide`
  lives in `GateEngine`) stays in the root module — here we do not DECIDE the route, we DECODE and RENDER.

  ## A single module (decoding + rendering coupled)

  Rendering and decoding are NOT independent: `eng_summary/1` (rendering of the eng voice)
  relies on `unwrap_worker_envelope/1` (decoding of the worker envelope) to reach the
  `summary` field. Decoding and rendering thus share the same unwrapping primitive + the `safe_str/1` coercion —
  splitting into `Verdict.Decode`/`Verdict.Render` would create a Render→Decode dependency and separate
  functions that manipulate the SAME wire artifact (the verdict envelope). The concern is one: reading and
  rendering a judge's verdict.

  ## Single authority of the vocabulary

  `gate_decision/1` relies on `@gate_decisions = Fleet.Workflow.GateDecision.decisions()` — the
  canon list is NOT copied: it is evaluated at compile from the single authority
  `Fleet.Workflow.GateDecision` (this module recompiles if the canon list changes). Fail-closed:
  absent/unknown decision → `"halt_invalid"` (never `"continue"` on a malformed verdict).
  """

  # Canon vocab = SINGLE AUTHORITY `Fleet.Workflow.GateDecision` (evaluated at compile → literal list,
  # usable in the `in` guard below; this module recompiles if the canon list changes).
  @gate_decisions Fleet.Workflow.GateDecision.decisions()

  # ============================================================
  # Decoding — reading the decision buried in the envelopes
  # ============================================================

  @doc false
  # Extracts the decision from the `work_item.completed` payload. TWO envelopes: (1) TaskQueue sets
  # `:result` (atom key); (2) worker envelope `%{"status","result"}` (string keys).
  def gate_result(payload) when is_map(payload) do
    (Map.get(payload, :result) || Map.get(payload, "result"))
    |> unwrap_worker_envelope()
  end

  def gate_result(_), do: nil

  @doc false
  # Fail-closed: nil/unknown → "halt_invalid" (never "continue" on an absent/malformed decision →
  # routes to await_arch). `halt_invalid` is NOT in the canon list (it is the internal fallback).
  def gate_decision(result) when is_map(result) do
    case result["decision"] do
      d when d in @gate_decisions -> d
      _ -> "halt_invalid"
    end
  end

  def gate_decision(_), do: "halt_invalid"

  @doc false
  # Unwraps the worker envelope `%{"status","result"}`. The worker returns either directly
  # `%{"decision"=>...}` / the outputs, or the envelope `%{"status"=>"ok","result"=>...}`.
  # Without unwrapping: decision/outputs buried → false escalation / wrongful hard-gate.
  def unwrap_worker_envelope(%{"decision" => _} = direct), do: direct
  def unwrap_worker_envelope(%{"status" => _, "result" => inner}) when is_map(inner), do: inner
  def unwrap_worker_envelope(other), do: other

  # ============================================================
  # Text rendering — verdict trace / review body / eng voice
  # ============================================================

  @doc false
  # Readable verdict trace (carried in the step_run comment → durable in the forge). `judge_label`
  # parameterizes the ATTRIBUTION (gatekeeper, consultant, …) → honest forge traceability (the right judge named).
  # `halt_invalid` is NOT a rendered decision: it is the internal fail-closed fallback (absent/malformed
  # verdict) → distinct message so as not to make it look like a "halt_invalid" verdict.
  def verdict_comment(judge_label, "halt_invalid", _result) do
    "Verdict du **#{judge_label}** illisible ou absent (fail-closed) → escalade humaine."
  end

  def verdict_comment(judge_label, decision, result) do
    reason = if is_map(result), do: Map.get(result, "reason")

    base = "Verdict du **#{judge_label}** — décision : `#{decision}`."

    if is_binary(reason) and reason != "", do: base <> "\nMotif : #{reason}", else: base
  end

  @doc false
  # SINGLE TABLE token → forge review-event (`:approve` | `:request_changes`), fail-closed. TWO
  # DISJOINT vocabularies converge here (no collision: decisions are STRINGS, intents are ATOMS):
  #   * gate-decision (no-workflow_map judge, caller `StepRunConsumer`): `"continue"`→approve;
  #     everything else (`abandon`/redirect/escalate/halt/unreadable)→**request_changes** (DECISIVE
  #     fail-closed: a non-`continue` verdict = not green → we block the merge, never a merge on
  #     a dubious verdict).
  #   * gate intent (workflow_map judge, caller `StepRunCompleter`): ONLY the gate-PASS
  #     intents approve, each one EXPLICITLY — `:advance` (a step follows) and `:promote`
  #     (terminal) = APPROVED; `:rework` (gate fail) = REQUEST_CHANGES.
  # Shared FAIL-CLOSED default: any other token (a future `:reject`/`:abandon`, a step_run that
  # lost its `:review_event`) NEVER auto-approves — approving by OMISSION is the worst
  # default for a verdict. The catch-all blocks; approving stays an engraved choice, token by token.
  def review_event("continue"), do: :approve
  def review_event(:advance), do: :approve
  def review_event(:promote), do: :approve
  def review_event(_other), do: :request_changes

  @doc false
  # Composes the review body from the judge's gate-decision. `nil` if no substance (→ the
  # generic default of `record_review`, which carries at least the rework instruction).
  def judge_review_body(event, result) when is_map(result) do
    reason = result |> Map.get("reason") |> safe_str() |> String.trim()
    details = format_review_details(Map.get(result, "details"))
    chain = format_review_chain(Map.get(result, "chain"))
    substance = Enum.reject([reason, details, chain], &(&1 in [nil, ""]))

    if substance == [] do
      nil
    else
      verdict = if event == :approve, do: "APPROUVÉ", else: "CHANGEMENTS DEMANDÉS"

      ["**#{verdict}** — verdict du juge.", reason, details, chain]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")
    end
  end

  def judge_review_body(_event, _), do: nil

  @doc false
  # ENG VOICE (OUTGOING info): the PRODUCER can return a markdown `summary` in submit_result
  # (what it did / response to the review / blocked reason). We extract it from the result (unwrapped from
  # the worker envelope) → `StepRunCompleter` posts it as a PR comment (`as_role` engineer). Coerced by
  # `safe_str` (the eng may return a non-binary → don't crash the singleton). Absent/empty → "".
  def eng_summary(payload) do
    case unwrap_worker_envelope(payload["result"] || %{}) do
      m when is_map(m) -> m |> Map.get("summary") |> safe_str() |> String.trim()
      _ -> ""
    end
  end

  # Safe coercion of LLM outputs: a judge may return `reason`/`details`/`chain` as nested objects or
  # lists → raw interpolation/`to_string` crashes (String.Chars not implemented for Map/List). Every
  # non-binary is `inspect`ed. CRITICAL: building the body MUST NOT crash the StepRunConsumer
  # (SINGLETON) — otherwise the step-run completion is lost, the lock never released, the pipe wedged.
  defp safe_str(nil), do: ""
  defp safe_str(s) when is_binary(s), do: s
  defp safe_str(other), do: inspect(other)

  defp format_review_details(d) when is_map(d) and map_size(d) > 0,
    do:
      "**Détails**\n" <>
        Enum.map_join(d, "\n", fn {k, v} -> "- **#{safe_str(k)}** : #{safe_str(v)}" end)

  defp format_review_details(_), do: nil

  defp format_review_chain(c) when is_list(c) and c != [],
    do: "**Raisonnement**\n" <> Enum.map_join(c, "\n", fn item -> "- #{safe_str(item)}" end)

  defp format_review_chain(_), do: nil
end
