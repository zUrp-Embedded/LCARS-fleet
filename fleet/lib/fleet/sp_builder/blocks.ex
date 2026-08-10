defmodule Fleet.SPBuilder.Blocks do
  @moduledoc """
  Deterministic per-role system-prompt composition from an ordered block map.
  Blocks carry substrate contracts only; higher-domain contracts arrive through
  briefs. Missing roles or blocks fail hard.

  ## The blocks are a SEARCH PATH, and `core/` is a shipped default

  A block name is resolved through `Fleet.Catalogue.find/3`, business root first — so the seven
  `core/` blocks live in the system catalogue and an author supersedes one by writing a file at the
  same relative path. Nothing is written to the system's disk; remove the override and its default
  is back, intact.

  Why they are there rather than in a runtime tree with no door: `core/` is 148 lines of FRENCH
  prose describing the runtime contract, and a deployment that rewrites its prompts in another
  language would receive it untouched under English SPs. Franglais by construction. What the
  runtime actually owns are the IDENTIFIERS the prose carries — `get_work_item`, `submit_result`,
  `work_item_id`, `brief_ref`, `Monitor`, `watch.sh`, `turn.flag`, `LCARS_POD_DIR`,
  `halt_wait_input`, `engage` — and those survive a rewrite because the runtime sends and reads
  them. The identifiers are the contract; the FILE is a default.

  `sp-map.yaml` is deliberately NOT on the search path: it is the author's manifest, not a default.
  A catalogue that composes brings its own; one that ships hand-written drafts needs none.
  """

  # `Date:` up front → satisfies the GO-7 hook (`<!--\s*Date\s*:`) without polluting the SP with a visible
  # markdown header. STATIC date (not `Date.utc_today`): generation must stay deterministic (the no-drift
  # test compares the committed flat to a regeneration — a dynamic date would break it the next day). The
  # header text stays FR: it is SP-file content (pod-facing convention).
  @header "<!-- Date: 2026-07-08 — SP v2 : fichier GÉNÉRÉ par `mix lcars.sp.gen` depuis sp_builder/sp_blocks/. " <>
            "NE PAS ÉDITER (édite les blocs). Bloc ou rôle manquant → échec dur (no-fallback, cf. no-sp-no-pod-no-fleet). -->"

  @doc """
  Role → ordered block list, read from `<blocks_dir>/sp-map.yaml` — the BUSINESS root only.
  """
  @spec role_map(Path.t()) :: %{String.t() => [String.t()]}
  def role_map(blocks_dir) do
    blocks_dir |> Path.join("sp-map.yaml") |> YamlElixir.read_from_file!()
  end

  @doc "Composed SP for one role. Fail-loud if a listed block is missing, or if the list is empty."
  @spec compose!(String.t(), [String.t()], Path.t()) :: String.t()
  def compose!(role, blocks, blocks_dir)
      when is_binary(role) and is_list(blocks) and blocks != [] do
    body = Enum.map_join(blocks, "\n\n", &read_block!(role, &1, blocks_dir))
    Enum.join([@header, "# System Prompt — #{role}", body], "\n\n") <> "\n"
  end

  def compose!(role, _blocks, _dir),
    do:
      raise(
        "SP blocks: role #{inspect(role)} has no blocks in sp-map.yaml (no-fallback: no SP → no pod)"
      )

  # A generated draft SAYS SO, in its first line. That marker is what tells a composed SP from a
  # hand-written one, and `audit!/2` needs the distinction: overwriting someone's hand-written SP
  # because a block map happened to name its role is the one destructive thing this generator could
  # do. Matching the header text rather than a side file keeps the fact ON the artifact.
  @generated_marker "GÉNÉRÉ par `mix lcars.sp.gen`"

  @doc """
  Refuses a catalogue whose ROLES and BLOCKS disagree, naming every disagreement at once.

  `sp-map.yaml` has carried this promise in its header since it was written — *"a catalogue role
  with no entry here → the generator FAILS (fail-loud)"* — and nothing enforced it: `generate!/2`
  iterates the MAP, never the catalogue, so a role absent from both simply was not generated and
  died much later at spawn with `:agent_draft_missing`. The comment described the code it should
  have had.

  Three disagreements, and the asymmetry between them is the model:

    * a role with **neither** a map entry nor a draft — the promised refusal. It has no SP, and no
      SP means no pod.
    * a map entry naming a role the catalogue does **not** carry — blocks composed for a ghost. Not
      fatal at spawn, which is exactly why nothing would ever report it.
    * a map entry **and** a hand-written draft — two sources for one SP, and the generator would
      silently overwrite the hand-written one. A GENERATED draft is not a conflict: that is the
      normal state after composing, and it is what the marker distinguishes.

  A role with a draft and no map entry is legitimate and NOT reported: that is the hand-written
  family (the architect and starfleet twins, and every role of a catalogue that composes nothing).
  """
  @spec audit!([String.t()], %{String.t() => [String.t()]}) :: :ok
  def audit!(roles, map) when is_list(roles) and is_map(map) do
    mapped = MapSet.new(Map.keys(map))
    known = MapSet.new(roles)

    ghosts = mapped |> MapSet.difference(known) |> Enum.sort()

    orphans =
      Enum.sort(for r <- roles, not MapSet.member?(mapped, r), not has_draft?(r), do: r)

    doubles =
      Enum.sort(for r <- roles, MapSet.member?(mapped, r), hand_written?(r), do: r)

    problems =
      [
        {orphans, "carry NEITHER an sp-map entry NOR a draft (no SP means no pod)"},
        {ghosts, "are named by sp-map.yaml and absent from the catalogue (blocks for a ghost)"},
        {doubles,
         "carry BOTH an sp-map entry and a HAND-WRITTEN draft — composing would overwrite it"}
      ]
      |> Enum.reject(fn {names, _} -> names == [] end)
      |> Enum.map_join("; ", fn {names, why} -> "#{Enum.join(names, ", ")} #{why}" end)

    if problems != "" do
      raise "SP blocks: #{problems}. Each role owes exactly one source for its SP — a block list " <>
              "or a draft, never both, never neither (no-fallback)."
    end

    :ok
  end

  defp has_draft?(role), do: role |> Fleet.SPBuilder.sp_draft_path() |> File.regular?()

  defp hand_written?(role) do
    path = Fleet.SPBuilder.sp_draft_path(role)

    File.regular?(path) and not String.contains?(File.read!(path), @generated_marker)
  end

  @doc """
  Generate ALL `agent-<role>-base.md` flats from the map, into `drafts_dir`. Returns the generated roles.
  """
  @spec generate!(Path.t(), Path.t(), keyword()) :: [String.t()]
  def generate!(blocks_dir, drafts_dir, opts \\ []) do
    confined? = Keyword.get(opts, :confined?, false)

    blocks_dir
    |> role_map()
    |> Enum.map(fn {role, blocks} ->
      target =
        if confined?,
          do: Path.join(drafts_dir, "agent-#{role}-base.md"),
          else: draft_target(drafts_dir, role)

      File.write!(target, compose!(role, blocks, blocks_dir))
      role
    end)
    |> Enum.sort()
  end

  # A draft is written NEXT TO THE ROLE IT SERVES: a mechanism role's in the system catalogue, a
  # business role's in the business one. This is what lets the system catalogue carry its OWN
  # gatekeeper and chief drafts — proven on a bench by removing the business catalogue from the
  # release and booting anyway — while the map that generates them lives with the reference.
  #
  # An EXISTING file decides, because the role's home is a fact on disk, not something to infer.
  # A role with no draft yet is new business material and lands in `drafts_dir`; adding a mechanism
  # role is a deliberate act that starts by creating its file where it belongs.
  #
  # ⚠ CONFINED (`--catalogue <root>`) TURNS THIS OFF, and it must. Measured 2026-08-10 by running
  # the documented gesture: an operator composing THEIR catalogue with a `gatekeeper` entry in their
  # map OVERWROTE the shipped system draft — the one file the target state calls never modifiable.
  # Their `gatekeeper` is their OVERRIDE of it, and an override belongs in their own tree, where the
  # search path makes it win. The rule read correctly is the same one: a draft goes where its MAP
  # is, and an explicit root says which map is being composed.
  defp draft_target(drafts_dir, role) do
    file = "agent-#{role}-base.md"
    system = Path.join([Fleet.Catalogue.system_root(), "sp_builder/sp_drafts", file])

    if File.regular?(system), do: system, else: Path.join(drafts_dir, file)
  end

  # Resolved through the catalogue door, so `core/*` reaches the system default while an author's
  # own block at the same relative path wins. The refusal names the path the resolver LANDED on,
  # never the one it looked for first: reading "core/runtime-contract.md unreadable" under the
  # business root while the system copy exists would send its reader to fix the wrong tree.
  defp read_block!(role, block, blocks_dir) do
    path = Fleet.Catalogue.find(blocks_dir, Fleet.Catalogue.rel(:sp_blocks), block <> ".md")

    case File.read(path) do
      {:ok, content} ->
        content |> strip_leading_comment() |> String.trim_trailing()

      {:error, reason} ->
        raise "SP blocks: role #{role} — block `#{block}` unreadable (#{path}): #{inspect(reason)} (no-fallback)"
    end
  end

  # Strip the leading `<!-- Date: … -->` HTML header of a block (present ONLY to satisfy GO-7 on the source
  # file) → it never reaches the composed SP, zero pollution.
  defp strip_leading_comment(content), do: String.replace(content, ~r/\A\s*<!--.*?-->\s*/s, "")
end
