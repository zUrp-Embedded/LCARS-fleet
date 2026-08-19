defmodule Fleet.Pilot.ConflictReport do
  @moduledoc """
  Renders a conflict diagnosis into a report a human can read on the PR.

  `Fleet.Conflict` names the `DecisionTrace` its durable value — "every evaluated pattern is
  recorded; the REFUSAL is documented as much as the acceptance; the durable audit artifact". It is
  produced per hunk, carried by each `Report`, and `Remediation` reads the TOTALS and nothing else.
  So the artifact was computed on every conflict and reached no reader: the engine wrote a machine's
  worth of reasoning and published a count.

  That matters most on the path where the machine WRITES. An auto-resolution pushes to a producer's
  branch, and the only trace was a commit authored by the runtime (`system_starfleet` since A2 — the
  engine minted itself `lcars-conflict-engine` before the function had a name). A human seeing an
  unexpected line asks "why did the machine touch this", and the answer existed, in memory, and was
  dropped one function before it could be posted.

  ## Two audiences, one render

  On an auto-resolution the report answers "what did the machine do to my branch, and why was it
  allowed to". On an all-semantic hand-off it answers "why did nothing get resolved" — which is the
  brief the chief would otherwise have to reconstruct by re-running the diagnosis in its head.

  Pure: `render/2` takes the diagnosis and returns a string. No forge, no I/O — the posting is the
  caller's, and this stays testable without a git repo.
  """

  @doc """
  Renders `diagnosis` (`%{files: %{path => Report.t()}, totals: …}`) for `outcome`.

  `outcome` is `:auto_resolved` (the machine wrote) or `:all_semantic` (nothing was trivial), and it
  only changes the opening sentence: the same evidence answers both questions, and rendering two
  shapes would let the two drift.
  """
  @spec render(map(), :auto_resolved | :all_semantic) :: String.t()
  def render(diagnosis, outcome) when is_map(diagnosis) do
    files = Map.get(diagnosis, :files, %{})
    totals = Map.get(diagnosis, :totals, %{})
    do_render(files, totals, outcome)
  end

  # TOTAL, and deliberately so: this render feeds a BEST-EFFORT report. A diagnosis of an unexpected
  # shape must produce a thinner report, never a `FunctionClauseError` that would kill the
  # auto-resolution or the hand-off the report only describes. An explanation is not allowed to
  # break the act it explains.
  def render(_diagnosis, outcome), do: do_render(%{}, %{}, outcome)

  defp do_render(files, totals, outcome) do
    [
      headline(outcome, totals),
      "",
      summary_line(totals),
      "",
      files_section(files),
      "",
      footer(outcome)
    ]
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp headline(:auto_resolved, _totals),
    do:
      "## Conflit de merge résolu automatiquement\n\n" <>
        "Le moteur déterministe a résolu ce conflit et poussé le résultat. **Les juges re-jugent " <>
        "le nouveau head** — une résolution fausse est rattrapée là, elle n'entre pas dans `main` " <>
        "sur la seule parole du moteur."

  defp headline(:all_semantic, _totals),
    do:
      "## Conflit de merge : rien n'est résoluble mécaniquement\n\n" <>
        "Le moteur déterministe n'a trouvé aucun hunk qu'il puisse résoudre seul. Le round de " <>
        "producteur est SAUTÉ sur cette preuve — il ne redécouvrirait que ça — et la passe " <>
        "d'exception prend la main."

  defp summary_line(totals) do
    "**#{Map.get(totals, :total, 0)} hunk(s)** — #{Map.get(totals, :trivial, 0)} superficiel(s), " <>
      "#{Map.get(totals, :complex, 0)} sémantique(s), " <>
      "#{Map.get(totals, :writable, 0)} que la machine s'autorise à écrire."
  end

  # No per-file detail means the diagnosis reached us without its `files` — the totals still route
  # correctly, so the report says what it has and NAMES what it lacks. A section silently omitted
  # reads as "there was nothing there".
  defp files_section(files) when files == %{},
    do: "_(pas de détail par fichier dans ce diagnostic — seuls les totaux étaient disponibles)_"

  defp files_section(files),
    do: files |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join("\n", &file_section/1)

  defp file_section({path, %{hunks: hunks}}) do
    "### `#{path}`\n\n" <> Enum.map_join(hunks, "\n", &hunk_line/1)
  end

  defp file_section({path, _no_hunks}),
    do: "### `#{path}`\n\n- _(rapport sans hunks — rien à détailler)_"

  # One line per hunk: what it was classified as, how sure, and the trace's own summary — the
  # sentence the classifier wrote when it decided, not one re-derived here.
  #
  # Read by FIELD, never by matching `%Fleet.Conflict.Hunk{}`, and for two converging reasons. The
  # boundary exports `Conflict.Report` alone, so naming the inner struct from `Pilot` would mean
  # widening a domain's declared API to render a comment. And the match would be actively wrong
  # here: this render is best-effort by contract, so a `FunctionClauseError` on an odd element would
  # kill the auto-resolution it merely describes. Total access, total fallbacks.
  defp hunk_line(h) when is_map(h) do
    "- ligne #{Map.get(h, :start_line, "?")} — `#{Map.get(h, :type, :unknown)}` " <>
      "(confiance `#{confidence_label(h)}`) : #{trace_summary(h)}"
  end

  defp hunk_line(_), do: "- _(élément de hunk illisible)_"

  defp confidence_label(%{confidence: %{label: l}}), do: l
  defp confidence_label(_), do: "?"

  defp trace_summary(%{trace: %{summary: s}}) when is_binary(s) and s != "", do: s
  defp trace_summary(%{explanation: e}) when is_binary(e) and e != "", do: e

  # Neither present is a defect of the ENGINE, not of this render: a hunk reached a router with no
  # recorded reason. Said, never blanked — an empty bullet reads as "nothing to say".
  defp trace_summary(_), do: "_(aucune trace enregistrée pour ce hunk — anomalie du classifieur)_"

  defp footer(:auto_resolved),
    do:
      "_Rapport du moteur de conflit. Le commit de résolution est signé " <>
        "`#{Fleet.Credentials.ForgeIdentity.system_identity().name}` — le moteur du runtime a tenu " <>
        "le stylo ; ce rapport est posté par le " <>
        "chief, à qui l'acte appartient, et le merge sera scellé en son nom._"

  defp footer(:all_semantic),
    do:
      "_Rapport du moteur de conflit, posté par le chief. Aucune écriture n'a été faite sur la " <>
        "branche._"
end
