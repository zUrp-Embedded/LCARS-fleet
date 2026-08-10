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

  @doc """
  Generate ALL `agent-<role>-base.md` flats from the map, into `drafts_dir`. Returns the generated roles.
  """
  @spec generate!(Path.t(), Path.t()) :: [String.t()]
  def generate!(blocks_dir, drafts_dir) do
    blocks_dir
    |> role_map()
    |> Enum.map(fn {role, blocks} ->
      File.write!(draft_target(drafts_dir, role), compose!(role, blocks, blocks_dir))
      role
    end)
    |> Enum.sort()
  end

  # A draft is written NEXT TO THE ROLE IT SERVES: a mechanism role's in the system catalogue, a
  # business role's in the business one. Writing every draft to one root would put a second
  # `agent-gatekeeper-base.md` beside the system's, and two drafts for one name is a refusal at
  # image publish — the generator would break the deployment it exists to keep in sync.
  #
  # An EXISTING file decides, because the role's home is a fact on disk, not something to infer.
  # A role with no draft yet is new business material and lands in `drafts_dir`; adding a mechanism
  # role is a deliberate act that starts by creating its file where it belongs.
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
