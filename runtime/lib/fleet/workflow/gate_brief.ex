defmodule Fleet.Workflow.GateBrief do
  @moduledoc """
  Builds the **eval brief** (the brief text) sent to a judge to decide a workflow gate.
  The judge pulls it via MCP `get_work_item`, judges (rubber-duck modop), and returns a
  strict JSON decision `gate-decision.json`.

  The FRAMING prose lives in `priv/catalogue/workflow/brief_templates/gate-brief-{deliverable,brief}.md`
  (F-23: wording is calibration DATA — cf. `Fleet.Workflow.BriefTemplate`); this module
  fills the mechanical slots (context values, JSON renderings, decision vocab) and
  DEFUSES the quoted material (blockquotes — the executable state is unrepresentable).

  ONE EXCEPTION, stated because "the prose lives in the templates" read as absolute and is not: the
  subject body (`subject_body(:brief, …)` below) is written HERE, in French. What it carries is not
  tone — it is PROTOCOL: the resolved text AND the sha it was resolved at, so the judge reads what
  it judges and cites the version it read. Its imperative half ("cite this sha in your verdict") IS
  calibration, and moving that half to a template — the fragment mechanism already exists, cf.
  `gate-brief-request-section` — is what it would take to tune the wording without a deploy. Until
  then: framing in templates, protocol in code, and the reader is told which is which rather than
  discovering the exception.

  Pure function over its inputs + the template files (fail-loud on a missing/miswired
  template — a judge never receives a half-rendered order).
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
  verdict contract (`gate-decision`) and the mechanics are identical — each subject has
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

  # :brief MOUNTED → the brief the scoper judges is a content-addressed file it READS, not text
  # quoted into the order (transport_brief_v2). The order names the mount and NOTHING of the pin:
  # the sha is the runtime's to engrave (commit message + forge), never the agent's to relay. Same
  # stance as the producer's order and the deliverable judge's criterion — one transport, no
  # exception of role. The `<mount>` name here is set by `BriefBuilder.build_brief_review_brief`.
  defp subject_body(:brief, %{"brief_mount" => file}) when is_binary(file) do
    "Ce que tu juges est le fichier `~/issues/#{file}`, monté en lecture seule dans ton pod : le " <>
      "brief d'auteur figé pour toi, adressé par contenu. Lis-le entièrement, puis évalue-le — est-il " <>
      "exécutable tel quel, sans nouvelle question ? Ne l'exécute pas : tu juges le brief, pas la tâche."
  end

  # :brief inline (degraded dispatch, no authored doc) → READABLE defused blockquote (E2 — a
  # JSON-escaped one-line blob is unreadable at scale). :deliverable → step outputs as pretty
  # JSON (structured data).
  defp subject_body(:brief, %{"brief" => brief}) when is_binary(brief), do: blockquote(brief)
  defp subject_body(:brief, outputs), do: blockquote(render_json(outputs))
  defp subject_body(_deliverable, outputs), do: render_json(outputs)

  defp gate_type(%{"type" => t}), do: t
  defp gate_type(_), do: "—"

  # Original request is defused judgement context, not an instruction.
  defp request_section(req) when is_binary(req) and req != "" do
    BriefTemplate.render("gate-brief-request-section", %{"request_quoted" => blockquote_tail(req)})
  end

  defp request_section(_), do: ""

  # Template owns the leading quote marker.
  defp blockquote_tail(text), do: String.replace(text, "\n", "\n> ")
  defp blockquote(text), do: "> " <> blockquote_tail(text)

  # Readable JSON with defensive fallback.
  defp render_json(nil), do: "(none)"

  defp render_json(term) do
    case Jason.encode(term, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(term, pretty: true)
    end
  end
end
