defmodule Fleet.ReceptionFilter do
  use Boundary, deps: [], exports: []

  @moduledoc """
  The MECHANICAL reception filter — the V1 doctrine's REFUSE_PATTERNS, ported (BL-6-16).

  Doctrine (`ipc-reception-filter.md`, moon-shot corpus, active): a critical property holds
  only when pushed down to a layer that enforces it mechanically. The property here: material
  authored OUTSIDE the fleet's trust boundary (a target repo's instruction files) must never
  reach an agent's directive tier carrying a destructive-operation prompt. The filter is a
  REGEX, applied BEFORE any LLM cognition, refuse-by-default on match.

  Consumers: `Fleet.SPBuilder.RepoSections` (sections lifted from a repo `CLAUDE.md` into the
  pod's composed doc — a matching section is DROPPED, loud) and the external-import adoption
  gate (a matching file REFUSES the import — BL-6-31). Foundation (`deps: []`): both Pilot and
  SPBuilder reach it without a boundary widening.

  The pattern list is EXTENSIBLE, NEVER reducible (doctrine rule): each addition carries its
  justification in place; a removal requires a user-validated decision, engraved.

  This defends V1-V3 of the doctrine's threat model (drift, pipeline bug, project-content
  injection). V4 (a sophisticated attacker paraphrasing around the patterns) is explicitly
  OUT of scope, as in the doctrine — the filter is a floor, never the whole defense.
  """

  # The canonical V1 list, verbatim semantics, TWO corrections carried with their why:
  # - case-insensitive across the board (hostile prose costs nothing to uppercase);
  # - `\s--?` instead of the original `\b--?` before flag dashes: `\b` NEVER holds between a
  #   space and a dash (both non-word), so the python original could not match its own
  #   canonical example ("git push --force") — a latent hole in the doctrine's list, fixed
  #   here (an extension in coverage, never a reduction).
  # The French patterns keep their accents: they are MATCHING LITERALS (data against hostile
  # French text), not source prose.
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

  @typedoc "A match: the pattern's LABEL (stable, loggable) + the first offending line (capped)."
  @type match :: {:match, String.t(), String.t()}

  @doc """
  Scans `content` against the canonical patterns. `:clean` or `{:match, label, excerpt}` —
  the FIRST match wins (one named refusal is enough to act; the caller drops/refuses the
  whole unit, never trims around a match).
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
