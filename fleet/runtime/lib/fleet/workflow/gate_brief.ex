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
  source-pointer body (`subject_body(:brief, …)` below) is written HERE, in French, like its twin
  `BriefArtifact.pointer_brief/2`. What those two carry is not tone — it is PROTOCOL: ONE address,
  `git show <sha>:<ref>`, which is the pinned object itself. Not the working-tree path with the pin
  as a fallback: that mount is a live bind of a worktree the architect holds in RW, so the path and
  the pin are not two ways of reading the same thing. Their imperative half
  ("read it in full before judging") IS calibration, and moving that half to a template — the fragment
  mechanism already exists, cf. `gate-brief-request-section` — is what it would take to tune the
  wording without a deploy. Until then: framing in templates, pointers in code, and the reader is told
  which is which rather than discovering the exception.

  Pure function over its inputs + the template files (fail-loud on a missing/miswired
  template — a judge never receives a half-rendered order).

  **Last revised**: 2026-08-03
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

  # :brief with a SOURCE pointer → the judged brief is NOT re-quoted (dedup, one source of truth):
  # the judge reads the authored doc AT ITS PIN. FR: prose rendered to the agent (same stance as the
  # git-native `livrable` pointer text).
  #
  # ONE address, and it is the sha. The path used to be given first, with the pin offered as a
  # fallback "if the file changed since" — a condition that requires its own answer to evaluate:
  # knowing whether the file moved means already holding the pinned version. An agent following it
  # literally either reaches for `git show` anyway, or reads the working tree and never evaluates
  # the condition at all — judging, in silence, a version nobody pinned.
  #
  # And the working-tree path is not an acceptable fallback: `LCARS_PROJECT_OPS` is a `--ro-bind`
  # of the very worktree the project architect holds in RW at the SAME path
  # (`LaunchSpec.project_ops_path/3` and `ProjectArchitect`'s work dir are both
  # `<work_root>/<project>`). The RO protects the pod, not the tree: it moves under the judge
  # mid-session. The sha addresses an immutable object.
  defp subject_body(:brief, %{"brief_ref" => ref, "brief_sha" => sha})
       when is_binary(ref) and is_binary(sha) do
    "Le brief à juger n'est PAS recopié ici (une seule source de vérité) : c'est le doc " <>
      "**`#{ref}`** de ton work/ops projet, à sa version PINNÉE au commit `#{sha}`. " <>
      "LIS-LE EN ENTIER avant de juger, par son pin : " <>
      "`git -C $LCARS_PROJECT_OPS show #{sha}:#{ref}`. C'est LA version à juger — le fichier " <>
      "de même nom dans l'arbre de travail n'est pas elle : ce mount est un bind vivant que " <>
      "l'architecte a en écriture."
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
