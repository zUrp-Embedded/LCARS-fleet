defmodule Fleet.ReceptionFilter do
  use Boundary, deps: [], exports: []

  @moduledoc """
  Regex reception filter for destructive-operation prompts in imported repository instructions.
  SPBuilder.RepoSections drops matching CLAUDE.md sections; the external-import adoption gate
  refuses matching files, before content reaches an agent's directive tier.

  The V1 REFUSE_PATTERNS policy (ipc-reception-filter.md) requires justification for additions
  and a recorded, user-validated decision for removals. Coverage targets drift, pipeline bugs
  and direct project-content injection (V1–V3); paraphrases by a sophisticated attacker (V4)
  are outside its scope. A clean result is not a general safety guarantee.
  """

  # Case-insensitive to catch uppercase instructions. Before flag dashes use whitespace:
  # \b does not match between a space and a dash, so it misses "git push --force".
  # Accented French literals are matching data and must retain their spelling.
  @refuse_patterns [
    {~r/\b(force[- ]?push|push[- ]?force)\b/i, "force-push"},
    {~r/\bpush\b.*\s--?force\b/i, "push --force"},
    {~r/\bpush\b.*\s--?no-verify\b/i, "push --no-verify"},
    {~r/\breset\b.*\s--?hard\b.*\b(main|master|work\/ops)\b/i, "reset --hard on a trunk"},
    {~r/\brebase\b.*\b(main|master|work\/ops)\b/i, "rebase of a trunk"},
    {~r/\bbranch\b.*\s-D\b.*\b(main|master)\b/i, "branch -D on a trunk"},
    {~r/\brm\b.*\.git\/hooks/i, "rm on .git/hooks"},
    {~r/\brm\b.*\/\.git\b/i, "rm on a .git"},
    {~r/\bchmod\b.*\.git\/hooks/i, "chmod on .git/hooks"},
    {~r/\bupdate-ref\b/i, "update-ref"},
    {~r/\bréécr(ire|iture).*historique/i, "reecriture d'historique (fr)"},
    {~r/\brewrite.*history/i, "history rewrite"},
    {~r/\bdétruire?.*git/i, "destruction git (fr)"},
    {~r/\bdestroy.*git/i, "git destruction"},
    {~r/--force-with-lease/i, "force-with-lease (destructive even leased)"}
  ]

  @typedoc "Pattern label and trimmed excerpt (up to 120 characters); empty if no individual line matches."
  @type match :: {:match, String.t(), String.t()}

  @doc """
  Returns :clean or {:match, label, excerpt}; pattern-list order determines the first match,
  not its position in the text. Callers reject the whole section/file rather than trimming around it.
  """
  @spec scan(String.t()) :: :clean | match()
  def scan(content) when is_binary(content) do
    case Enum.find(@refuse_patterns, fn {re, _label} -> Regex.match?(re, content) end) do
      nil -> :clean
      {re, label} -> {:match, label, excerpt(content, re)}
    end
  end

  # The first LINE carrying the match, capped — enough to name the refusal in a log without
  # replaying the hostile content at length.
  defp excerpt(content, re) do
    content
    |> String.split("\n")
    |> Enum.find("", &Regex.match?(re, &1))
    |> String.trim()
    |> String.slice(0, 120)
  end
end
