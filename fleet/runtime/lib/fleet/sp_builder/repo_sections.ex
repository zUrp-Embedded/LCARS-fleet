defmodule Fleet.SPBuilder.RepoSections do
  @moduledoc """
  Selective extraction of sections from the repo `CLAUDE.md` — the mini markdown
  parser split out of `Fleet.SPBuilder`, used by `compose_claude_md/3` to carry
  over into the pod's `CLAUDE.md` (N3) the useful sections of the target repo.

  Sections kept: `Stack`, `Build`, `Test`, `Conventions`, `Commands`, `Gotchas`
  — each level-2 markdown header (`## Name`) and its body up to the next level-2
  header. Everything else in the file is ignored (the repo CLAUDE.md also carries
  human sections with no value for a pod).

  **Pure** functions (FS read only for `read/1`, no process).

  **Last revised**: 2026-07-18
  """

  # Closed list of the sections carried over into the pod. The `\b` bounds the name on a
  # word boundary: `## Test suite` matches (space after `Test`), `## Testing` or
  # `## Stackoverflow` do not match (the word continues).
  @repo_section_re ~r/^##\s+(Stack|Build|Test|Conventions|Commands|Gotchas)\b/m

  @doc """
  Reads the repo `CLAUDE.md` and extracts the named sections from it.

    * `path = nil` → `{:ok, ""}` (no repo CLAUDE.md supplied: no section, not
      an error — the template renders the zone empty).
    * path supplied but unreadable → `{:error, {:repo_claude_md_unreadable, path, reason}}`
      (fail-loud: a supplied path MUST be readable, no silently-empty extraction).
  """
  @spec read(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def read(nil), do: {:ok, ""}

  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, extract(content)}
      {:error, reason} -> {:error, {:repo_claude_md_unreadable, path, reason}}
    end
  end

  @doc """
  Extracts from the markdown content the sections in the closed list (pure parser):
  splits at the `## ` headers, keeps the sections whose title matches, joins them
  by a blank line. Content with no named section → `""`.
  """
  @spec extract(String.t()) :: String.t()
  def extract(content) when is_binary(content) do
    lines = String.split(content, "\n")
    {sections_acc, current} = Enum.reduce(lines, {[], []}, &fold_section/2)

    [current | sections_acc]
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
    |> Enum.filter(&named_section?/1)
    |> Enum.map_join("\n\n", &Enum.join(&1, "\n"))
  end

  # Line-by-line fold: a `## ` header opens a new section (the accumulator
  # of the previous one is pushed), any other line is added to the current section.
  # The lists are built by prepending (O(1)) then reversed by `extract/1`.
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
