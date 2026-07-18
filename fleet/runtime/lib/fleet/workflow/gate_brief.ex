defmodule Fleet.Workflow.GateBrief do
  @moduledoc """
  Builds the **eval brief** (the brief text) sent to a judge to decide a workflow gate.
  The judge pulls it via MCP `get_work_item`, judges (rubber-duck modop), and returns a
  strict JSON decision `gate-decision-v1.json`.

  The PROSE lives in `priv/workflow/brief_templates/gate-brief-{deliverable,brief}.md`
  (F-23: wording is calibration DATA — cf. `Fleet.Workflow.BriefTemplate`); this module
  only fills the mechanical slots (context values, JSON renderings, decision vocab) and
  DEFUSES the quoted material (blockquotes — the executable state is unrepresentable).

  Pure function over its inputs + the template files (fail-loud on a missing/miswired
  template — a judge never receives a half-rendered order).

  **Last revised**: 2026-07-18
  """

  alias Fleet.Workflow.BriefTemplate

  # Decision vocab = SINGLE AUTHORITY `Fleet.Workflow.GateDecision` (evaluated at compile time, so
  # this brief recompiles if the canonical list changes — a local vocabulary could not drift from the
  # validator). The per-decision explanation LINES are template prose: a vocab change must be
  # mirrored there (the leftover-token belt catches a renamed slot, not a stale bullet).
  @decisions Fleet.Workflow.GateDecision.decisions()

  @doc """
  Renders the markdown brief from the gate context.

  `ctx`: `%{step: String, workflow_map_id: term, gate: map | nil, outputs: map,
  request: String | nil, subject: :deliverable | :brief}`.

  `:subject` parametrizes WHAT is judged — `:deliverable` (default: step outputs, rendered
  as JSON in a fence) or `:brief` (the BRIEF written by the architect, judged BEFORE any
  production — rendered as a readable markdown BLOCKQUOTE, never a JSON-escaped blob). The
  verdict contract (`gate-decision-v1`) and the mechanics are identical — each subject has
  its own template file carrying its own framing.
  """
  @spec build(map()) :: String.t()
  def build(%{step: step, workflow_map_id: pid} = ctx) do
    subject = Map.get(ctx, :subject, :deliverable)
    outputs = Map.get(ctx, :outputs, %{})

    BriefTemplate.render(template_name(subject), %{
      "pipeline" => inspect(pid),
      "step" => step,
      "gate_type" => gate_type(Map.get(ctx, :gate)),
      "request_section" => request_section(Map.get(ctx, :request)),
      "subject_body" => subject_body(subject, outputs),
      "gate_rules" => render_json(Map.get(ctx, :gate)),
      "decisions" => Enum.join(@decisions, " | ")
    })
  end

  defp template_name(:brief), do: "gate-brief-brief"
  defp template_name(_deliverable), do: "gate-brief-deliverable"

  # :brief → the judged brief as a READABLE defused blockquote (E2 — a JSON-escaped one-line
  # blob is unreadable at scale). :deliverable → step outputs as pretty JSON (structured data).
  defp subject_body(:brief, %{"brief" => brief}) when is_binary(brief), do: blockquote(brief)
  defp subject_body(:brief, outputs), do: blockquote(render_json(outputs))
  defp subject_body(_deliverable, outputs), do: render_json(outputs)

  defp gate_type(%{"type" => t}), do: t
  defp gate_type(_), do: "—"

  # Origin request = judgment CONTEXT, never an instruction to execute (otherwise the judge
  # redoes the previous step's task instead of judging). Blockquoted (defused) into the
  # request-section template; absent → empty slot.
  defp request_section(req) when is_binary(req) and req != "" do
    BriefTemplate.render("gate-brief-request-section", %{"request_quoted" => blockquote_tail(req)})
  end

  defp request_section(_), do: ""

  # The template carries the leading `> `; continuation lines get theirs here.
  defp blockquote_tail(text), do: String.replace(text, "\n", "\n> ")
  defp blockquote(text), do: "> " <> blockquote_tail(text)

  # Human-readable JSON rendering; fallback to inspect if non-encodable (defensive).
  defp render_json(nil), do: "(none)"

  defp render_json(term) do
    case Jason.encode(term, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(term, pretty: true)
    end
  end
end
