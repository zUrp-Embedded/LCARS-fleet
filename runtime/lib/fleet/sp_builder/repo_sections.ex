defmodule Fleet.SPBuilder.RepoSections do
  @moduledoc """
  Selects Stack, Build, Test, Doc, Conventions, Commands and Gotchas sections for
  SPBuilder's repository context. A section runs from a column-zero level-two header
  to the next such header. Matching is case-sensitive and accepts a word-boundary
  suffix (Test suite, not Testing). This line parser does not understand code fences.

  extract/1 is pure and unfiltered. read/1 reads disk, filters whole sections and logs
  omissions. No accepted section is a warning, not a failure: adopted repositories may
  use other headings, and new onboarded projects may not have written them yet.
  """

  require Logger

  # Doc carries documentation destination/expectations alongside Test's proof commands.
  @repo_section_re ~r/^##\s+(Stack|Build|Test|Doc|Conventions|Commands|Gotchas)\b/m
  # Keep the warning's expected names aligned with the matcher.
  @repo_section_names ~w(Stack Build Test Doc Conventions Commands Gotchas)

  @doc """
  Reads and filters named sections through ReceptionFilter. A matching section is
  omitted whole, logged as an error and named in a notice to the pod. The lexical filter
  can reject prohibitions as well as instructions; passing it does not prove text harmless.

  nil returns {:ok, ""} without warning. An unreadable supplied path returns
  {:error, {:repo_claude_md_unreadable, path, reason}}. Zero accepted sections warns;
  withheld sections may still contribute the notice to the successful result.
  """
  @spec read(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def read(nil), do: {:ok, ""}

  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        {kept, withheld} =
          content
          |> named_sections()
          |> Enum.reduce({[], []}, &admit_or_withhold(&1, &2, path))

        body = kept |> Enum.reverse() |> Enum.join("\n\n")
        {:ok, warn_if_no_section(body, path) <> withheld_notice(Enum.reverse(withheld))}

      {:error, reason} ->
        {:error, {:repo_claude_md_unreadable, path, reason}}
    end
  end

  defp admit_or_withhold(section, {kept, withheld}, path) do
    case Fleet.ReceptionFilter.scan(section) do
      :clean ->
        {[section | kept], withheld}

      {:match, label, excerpt} ->
        Logger.error(
          "RepoSections: section DROPPED from #{path} — reception filter matched " <>
            "#{inspect(label)} (#{inspect(excerpt)}); the section never reaches the pod's " <>
            "directives (BL-6-16)"
        )

        {kept, [section_name(section) | withheld]}
    end
  end

  defp section_name(section) do
    case Regex.run(~r/^##\s+(\S+)/, section) do
      [_, name] -> name
      _ -> "?"
    end
  end

  # Tell the pod constraints were withheld: lexical patterns also match "never rebase onto main".
  # Include only section names, never rejected excerpts, or the notice would reintroduce them.
  defp withheld_notice([]), do: ""

  defp withheld_notice(names) do
    liste = names |> Enum.uniq() |> Enum.map_join(", ", &"`#{&1}`")

    """


    ## ⚠ Sections retenues à la réception

    Le `CLAUDE.md` de ce dépôt porte ces sections, et elles ne t'ont PAS été transmises : #{liste}.

    Un filtre mécanique les a écartées : leur texte contient le motif d'une opération destructrice.
    Ce filtre ne distingue pas une consigne d'une mention — une section qui DOCUMENTE un interdit
    (« ne jamais rebaser sur main ») est écartée pour la même raison qu'une section qui l'ordonnerait.

    Ce que ça change pour toi : ce dépôt a des conventions écrites que tu n'as pas sous les yeux.
    Ne conclus pas de leur absence qu'il n'y en a pas. Sur un geste git destructeur ou irréversible,
    demande plutôt que de supposer.
    """
    |> String.replace(~r/^    /m, "")
    |> String.trim_trailing()
  end

  # Also runs when all matched sections were withheld; the existing log text is broader
  # than that case. No supplied path takes read(nil)'s separate, silent branch.
  defp warn_if_no_section("", path) do
    Logger.warning(
      "RepoSections: #{path} read but NO section matched #{inspect(@repo_section_names)} — the pod's " <>
        "CLAUDE.md carries no repo context. Either the repo names its sections differently, or it has none."
    )

    ""
  end

  defp warn_if_no_section(sections, _path), do: sections

  @doc """
  Extracts from the markdown content the sections in the closed list (pure parser):
  splits at the `## ` headers, keeps the sections whose title matches, joins them
  by a blank line. Content with no named section → `""`. UNFILTERED — the reception
  filter lives in `read/1` (the I/O door); this stays the pure structural half.
  """
  @spec extract(String.t()) :: String.t()
  def extract(content) when is_binary(content) do
    content |> named_sections() |> Enum.join("\n\n")
  end

  defp named_sections(content) do
    lines = String.split(content, "\n")
    {sections_acc, current} = Enum.reduce(lines, {[], []}, &fold_section/2)

    [current | sections_acc]
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
    |> Enum.filter(&named_section?/1)
    |> Enum.map(&Enum.join(&1, "\n"))
  end

  # Prepend while scanning, then reverse sections and their lines in named_sections/1.
  defp fold_section(line, {acc, current}) do
    if String.match?(line, ~r/^##\s+/) do
      {[current | acc], [line]}
    else
      {acc, [line | current]}
    end
  end

  defp named_section?([]), do: false
  defp named_section?([first_line | _]), do: Regex.match?(@repo_section_re, first_line)
end
