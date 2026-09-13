defmodule Fleet.Pilot.ConflictReport do
  @moduledoc """
  Renders per-hunk classification and trace summaries for auto-resolution or
  semantic hand-off reports. This exposes reasons that routing totals omit.
  Posting belongs to the caller; the auto-resolution footer reads the runtime identity.
  """

  @doc """
  Renders `%{files: %{path => Report.t()}, totals: map}` for `:auto_resolved`
  or `:all_semantic`, which select the headline and footer. Missing sections and
  non-map diagnoses have fallbacks; malformed nested values can still raise.
  """
  @spec render(map(), :auto_resolved | :all_semantic) :: String.t()
  def render(diagnosis, outcome) when is_map(diagnosis) do
    files = Map.get(diagnosis, :files, %{})
    totals = Map.get(diagnosis, :totals, %{})
    do_render(files, totals, outcome)
  end

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

  defp files_section(files) when files == %{},
    do: "_(pas de détail par fichier dans ce diagnostic — seuls les totaux étaient disponibles)_"

  defp files_section(files),
    do: files |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join("\n", &file_section/1)

  defp file_section({path, %{hunks: hunks}}) do
    "### `#{path}`\n\n" <> Enum.map_join(hunks, "\n", &hunk_line/1)
  end

  defp file_section({path, _no_hunks}),
    do: "### `#{path}`\n\n- _(rapport sans hunks — rien à détailler)_"

  # Read fields rather than matching the private Hunk struct: the domain exports Report.
  # Use the classifier's trace summary before its generic explanation.
  defp hunk_line(h) when is_map(h) do
    "- ligne #{Map.get(h, :start_line, "?")} — `#{Map.get(h, :type, :unknown)}` " <>
      "(confiance `#{confidence_label(h)}`) : #{trace_summary(h)}"
  end

  defp hunk_line(_), do: "- _(élément de hunk illisible)_"

  defp confidence_label(%{confidence: %{label: l}}), do: l
  defp confidence_label(_), do: "?"

  defp trace_summary(%{trace: %{summary: s}}) when is_binary(s) and s != "", do: s
  defp trace_summary(%{explanation: e}) when is_binary(e) and e != "", do: e

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
