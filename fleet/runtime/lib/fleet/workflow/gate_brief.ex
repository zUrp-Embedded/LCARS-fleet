defmodule Fleet.Workflow.GateBrief do
  @moduledoc """
  Builds the **eval brief** (the brief text) sent to the gatekeeper to
  decide a workflow gate. The gatekeeper pulls it via MCP `get_work_item`, judges
  (rubber-duck modop), and returns a strict JSON decision `gate-decision-v1.json`.

  Pure function. Template derived from `orchestration/gatekeeper-exception.md`
  §"Brief gatekeeper auto-généré" (invocation context + deliverable to judge +
  question to decide + deterministic options + output contract). The structured
  data also go into `task.metadata`; this brief is the human-readable form.

  **Last revised**: 2026-07-18
  """

  # Decision vocab = SINGLE AUTHORITY `Fleet.Workflow.GateDecision` (evaluated at compile time, so
  # this brief recompiles if the canonical list changes — no more local vocabulary drifting from the validator).
  @decisions Fleet.Workflow.GateDecision.decisions()

  @doc """
  Renders the markdown brief from the gate context.

  `ctx`: `%{step: String, workflow_map_id: term, gate: map | nil, outputs: map,
  request: String | nil, subject: :deliverable | :brief}`.

  `:subject` parametrizes WHAT is judged — `:deliverable` (default, the deliverable
  produced by a step: gatekeeper, PR judges) or `:brief` (the BRIEF written
  by the architect, judged BEFORE any production: brief-review/consultant). The
  verdict contract (`gate-decision-v1`) and the mechanics are identical — only the
  framing of the "thing to judge" changes (otherwise a brief judge would hunt a
  nonexistent deliverable). Default `:deliverable`.
  """
  @spec build(map()) :: String.t()
  def build(%{step: step, workflow_map_id: pid} = ctx) do
    gate = Map.get(ctx, :gate)
    outputs = Map.get(ctx, :outputs, %{})
    s = subject_phrases(Map.get(ctx, :subject, :deliverable), step)

    """
    # #{s.title}

    ⚠ YOUR ROLE IS TO **JUDGE**, NOT TO PRODUCE. Create NO file, commit
    NOTHING, run NO build task. #{s.intro} Your only output is a **decision** returned via `submit_result`.

    ## Context
    - Pipeline: #{inspect(pid)}
    - Judged step: #{step}
    - Gate: type #{gate_type(gate)}
    #{render_request(Map.get(ctx, :request))}
    ## Question to decide
    #{s.question}

    ## #{s.heading}
    ```
    #{render(outputs)}
    ```

    ## Gate rules (reference)
    ```
    #{render(gate)}
    ```

    ## Expected decision — strict JSON (`gate-decision-v1.json`)
    `{"decision": "<...>", "reason": "<structured rationale>", "details": {...}, "chain": [...]}`

    `decision` ∈ #{Enum.join(@decisions, " | ")}
    - `continue`: #{s.continue} → advance to the next step
    - `redirect`: send back to the architect (e.g. brief too big → ask for a split)
    - `abandon`: abandon the issue (not recoverable)
    - `escalate_user`: beyond the gatekeeper → the user decides
    - `halt_wait_input`: missing information → halt and wait

    ## How to return your decision
    Call `mcp__fleet__submit_result` with, as the **result**, the JSON object
    gate-decision-v1.json above. The `decision` field is MANDATORY and must
    be one of the listed values — without it, the runtime escalates to a human
    (fail-closed). Minimal example: `{"decision": "continue", "reason": "..."}`.
    """
  end

  # Framing of the "thing to judge", parametrized by `:subject`. `:deliverable` = the produced-deliverable
  # case (gatekeeper/PR-judges); `:brief` frames the brief review (the brief is written by
  # the arch, NOT yet executed → the judge does not look for a deliverable).
  defp subject_phrases(:brief, step) do
    %{
      # ROLE-NEUTRAL title: this brief goes to N judges (consultant in brief-review, qualifier/reviewer/
      # gatekeeper in deliverable). Calling it "gatekeeper" regardless of the judge makes a non-gatekeeper
      # judge adopt the wrong persona. The judged subject carries the title.
      title: "Brief eval — judge decision",
      intro: "The BRIEF to validate (written by the architect) is quoted below.",
      question:
        "The brief `#{step}` was written by the architect and has NOT been executed yet. Given the " <>
          "brief below, is it EXECUTABLE as-is (clear, complete, coherent, actionable by an " <>
          "engineer without further questions) — `continue` — or must it be sent back / escalated / abandoned?",
      heading: "Brief to judge (written by the architect — to validate BEFORE any execution)",
      continue: "the brief is executable as-is (clear, complete, actionable)"
    }
  end

  defp subject_phrases(_deliverable, step) do
    %{
      title: "Deliverable eval — judge decision",
      intro: "The deliverable already exists (it is quoted below).",
      question:
        "The step `#{step}` delivered its result. Given the deliverable below and the\n" <>
          "gate rules, should the gate be crossed (`continue`) — or abandon /\nsend back / escalate?",
      heading: "Deliverable to judge (step outputs — ALREADY produced, to evaluate)",
      continue: "the deliverable satisfies the gate"
    }
  end

  defp gate_type(%{"type" => t}), do: t
  defp gate_type(_), do: "—"

  # Origin request = judgment CONTEXT, never an instruction to execute
  # (otherwise the gatekeeper redoes the previous step's task instead of judging).
  # Explicitly framed and defused.
  defp render_request(req) when is_binary(req) and req != "" do
    """

    ## Original request (CONTEXT — already handled, DO NOT execute)
    > #{String.replace(req, "\n", "\n> ")}
    """
  end

  defp render_request(_), do: ""

  # Human-readable JSON rendering; fallback to inspect if non-encodable (defensive).
  defp render(nil), do: "(none)"

  defp render(term) do
    case Jason.encode(term, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(term, pretty: true)
    end
  end
end
