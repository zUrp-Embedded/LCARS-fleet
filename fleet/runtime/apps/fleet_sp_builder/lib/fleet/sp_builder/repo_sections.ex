defmodule Fleet.SPBuilder.RepoSections do
  @moduledoc """
  Extraction sélective des sections du `CLAUDE.md` repo — le mini-parser markdown
  extrait de `Fleet.SPBuilder`, utilisé par `compose_claude_md/3` pour reporter dans
  le `CLAUDE.md` du pod (N3) les sections utiles du repo cible.

  Sections retenues : `Stack`, `Build`, `Test`, `Conventions`, `Commands`, `Gotchas`
  — chaque header markdown de niveau 2 (`## Nom`) et son corps jusqu'au prochain
  header de niveau 2. Tout le reste du fichier est ignoré (le CLAUDE.md repo porte
  aussi des sections humaines sans valeur pour un pod).

  Fonctions **pures** (lecture FS only pour `read/1`, aucun process).
  """

  # Liste fermée des sections reportées dans le pod. Le `\b` borne le nom sur une frontière
  # de mot : « ## Test suite » matche (espace après `Test`), « ## Testing » ou
  # « ## Stackoverflow » ne matchent pas (le mot continue).
  @repo_section_re ~r/^##\s+(Stack|Build|Test|Conventions|Commands|Gotchas)\b/m

  @doc """
  Lit le `CLAUDE.md` repo et en extrait les sections nommées.

    * `path = nil` → `{:ok, ""}` (pas de repo CLAUDE.md fourni : aucune section, pas
      une erreur — le template rend la zone vide).
    * path fourni mais illisible → `{:error, {:repo_claude_md_unreadable, path, reason}}`
      (fail-loud : un path donné DOIT être lisible, pas d'extraction silencieusement vide).
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
  Extrait du contenu markdown les sections de la liste fermée (parser pur) :
  découpe aux headers `## `, garde les sections dont le titre matche, les rejoint
  par ligne vide. Contenu sans section nommée → `""`.
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

  # Fold ligne-à-ligne : un header `## ` ouvre une nouvelle section (l'accumulateur
  # de la précédente est poussé), toute autre ligne s'ajoute à la section courante.
  # Les listes sont construites en préfixe (O(1)) puis renversées par `extract/1`.
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
