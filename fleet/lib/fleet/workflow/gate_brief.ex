defmodule Fleet.Workflow.GateBrief do
  @moduledoc """
  Builds the **eval brief** (the brief text) sent to a judge to decide a workflow gate.
  The judge pulls it via MCP `get_work_item`, judges (rubber-duck modop), and returns a
  strict JSON decision `gate-decision-v1.json`.

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

  # :brief WITH its address → the text is quoted AND the pin is named. FR: prose rendered to the
  # agent (same stance as the git-native `livrable` text).
  #
  # THE SUBJECT IS HERE, IT IS NOT AN ERRAND. This used to carry only `{ref, sha}` and a
  # `git show` command against a mounted ops, which is what obliged every project pod to
  # carry the runtime's record so that one judge could read one file out of it. The runtime
  # resolves the pin at dispatch and ships the resolved text: the judge reads what it judges,
  # and it never holds the tree where what was asked of it is written down.
  #
  # THE PIN STAYS, and it is not decoration. It is what a third party uses to tie this verdict
  # back to a version, from the forge. What the judge loses is the ability to VERIFY the pairing
  # itself — and that verification was always against a live `--ro-bind` of the worktree the
  # architect holds in RW, so it could confirm nothing the runtime had not already resolved.
  defp subject_body(:brief, %{"brief" => brief, "brief_ref" => ref, "brief_sha" => sha})
       when is_binary(brief) and is_binary(ref) and is_binary(sha) do
    "Ce que tu juges est le doc d'auteur **`#{ref}`**, à sa version pinnée au commit " <>
      "`#{sha}` — résolu pour toi et recopié ci-dessous. Cite `#{String.slice(sha, 0, 7)}` " <>
      "dans ton verdict : c'est l'adresse de ce que tu as lu.\n\n" <> blockquote(brief)
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
