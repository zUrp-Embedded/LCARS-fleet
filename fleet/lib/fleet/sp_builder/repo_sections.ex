defmodule Fleet.SPBuilder.RepoSections do
  @moduledoc """
  Selective extraction of sections from the repo `CLAUDE.md` — the mini markdown
  parser split out of `Fleet.SPBuilder`, used by `compose_claude_md/3` to carry
  over into the pod's `CLAUDE.md` (N3) the useful sections of the target repo.

  Sections kept: `Stack`, `Build`, `Test`, `Doc`, `Conventions`, `Commands`, `Gotchas`
  — each level-2 markdown header (`## Name`) and its body up to the next level-2
  header. Everything else in the file is ignored (the repo CLAUDE.md also carries
  human sections with no value for a pod).

  **Pure** functions (FS read only for `read/1`, no process) — except the "nothing matched" warning,
  which `read/1` emits (never `extract/1`, which stays a pure parser).

  ## Bet on an adopted repo, CONTRACT on an onboarded one

  The distinction matters because the two produce the same silence and deserve opposite reactions.

  A repo LCARS did not create is free to name its sections otherwise and then contributes nothing.
  That outcome is legitimate, so it stays `{:ok, ""}` — but it is logged, because a pod launching
  with zero repo context is otherwise indistinguishable from a pod given no repo file at all.

  A repo LCARS onboarded is a different case: `priv/catalogue/project_template` ships a `CLAUDE.md`
  on each writer face, and the one on the code face NAMES these headings and explains what each is
  for. It deliberately leaves them CLOSED — a hollow heading makes the fleet believe it has context
  and the agent believe it has a command — so the warning on a fresh project is EXPECTED and says
  the sections have not been written yet, not that the convention was missed.

  """

  require Logger

  # Closed list of the sections carried over into the pod. The `\b` bounds the name on a
  # word boundary: `## Test suite` matches (space after `Test`), `## Testing` or
  # `## Stackoverflow` do not match (the word continues).
  # `Doc` is the twin of `Test`, on the other half of the same obligation. `Test` tells a producer
  # how to PROVE what it delivers; `Doc` tells it where the delivered documentation goes and what
  # is expected there. Without it, `docs/` is a directory every project has and no producer is ever
  # told to feed — and the documentation that ships gets written, if at all, by whoever notices.
  # It carries no `## Doc` for the DRAFTING face: that tree ships nothing, and its own CLAUDE.md
  # says so under `Conventions`.
  @repo_section_re ~r/^##\s+(Stack|Build|Test|Doc|Conventions|Commands|Gotchas)\b/m
  # Same list, readable — quoted in the "nothing matched" warning so the operator sees WHAT was expected.
  @repo_section_names ~w(Stack Build Test Doc Conventions Commands Gotchas)

  @doc """
  Reads the repo `CLAUDE.md`, extracts the named sections, and passes EACH through
  `Fleet.ReceptionFilter` (BL-6-16): the repo file is authored OUTSIDE the trust boundary and
  this is the door where its content becomes pod DIRECTIVES. A matching section is DROPPED
  whole and logged ERROR (red-alert class — the pod launches with LESS context, never with
  poison; a spawn is never wedged over prose).

    * `path = nil` → `{:ok, ""}` (no repo CLAUDE.md supplied: no section, not
      an error — the template renders the zone empty).
    * path supplied but unreadable → `{:error, {:repo_claude_md_unreadable, path, reason}}`
      (fail-loud: a supplied path MUST be readable, no silently-empty extraction).
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

  # The reception filter at the admission door (never a cleanup: the WHOLE section goes).
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

  # THE DROP WAS SILENT ON THE SIDE THAT MATTERS. The fleet logged `error`; the POD was told
  # nothing, and read a repo doc whose most prescriptive section had vanished. The filter's patterns
  # are LEXICAL and do not tell an instruction from a mention — `\brebase\b.*\bmain\b` matches
  # "rebase onto main" and "never rebase onto main" alike. So the section most likely to be dropped
  # is the one that DOCUMENTS the repo's prohibitions, i.e. exactly what `Conventions` and `Gotchas`
  # are for. The filter then produces the reverse of its intent: "never do X" is removed because it
  # mentions X, and the agent proceeds not knowing X is forbidden.
  #
  # The pattern list stays untouched — its own contract says EXTENSIBLE, NEVER REDUCIBLE, and
  # teaching it to tell a mention from an order is the V4 threat the doctrine puts out of scope.
  # What is fixed is the SILENCE: the pod now learns that constraints exist which it was not given.
  #
  # ⚠ THE NOTICE NAMES THE SECTIONS AND NEVER QUOTES THEM. Carrying the matched excerpt would
  # re-inject through the message exactly what the filter just refused — the door held, and the
  # notice about the door would walk it in.
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

  # THIRD state, previously folded into the first. This module already separates "no path supplied"
  # ({:ok, ""} — legitimate, the template renders an empty zone) from "path supplied but unreadable"
  # ({:error, …} — fail-loud). A path that IS readable and yields ZERO sections was silently
  # indistinguishable from the first: the pod launched with no repo context at all and nothing said so.
  # The closed list is a BET on the target repo's headings — LCARS does not impose them (its
  # `priv/catalogue/project_template` ships no CLAUDE.md), so a repo naming its sections `## Setup` /
  # `## Architecture` contributes nothing, legitimately and invisibly. Not an error (a repo owes us no
  # heading), so `{:ok, ""}` stands — but it is now VISIBLE. `extract/1` stays pure: the log lives here,
  # on the side that already does I/O.
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

  # The named sections as a LIST (one string each) — the shape `read/1` filters per-section.
  defp named_sections(content) do
    lines = String.split(content, "\n")
    {sections_acc, current} = Enum.reduce(lines, {[], []}, &fold_section/2)

    [current | sections_acc]
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
    |> Enum.filter(&named_section?/1)
    |> Enum.map(&Enum.join(&1, "\n"))
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
