defmodule Fleet.SPBuilder.Blocks do
  @moduledoc """
  Composes role prompts from ordered block lists, reading live catalogue files.
  Business blocks override system defaults through Catalogue.find/3; removing an override
  restores the default. Prose can be translated, but runtime identifiers such as get_work_item,
  submit_result, work_item_id, brief_ref, Monitor, watch.sh, turn.flag, LCARS_POD_DIR,
  halt_wait_input and engage must retain their operational spelling.

  sp-map.yaml is read only from the supplied blocks_dir: composing catalogues own their
  manifest, while hand-written drafts need no map. Callers must provide trusted role/block
  names and invoke audit!/2 separately before generation when overwrite protection is needed.
  """

  # Static Date header satisfies GO-7 without making regenerated drafts change every day.
  @header "<!-- Date: 2026-07-08 — SP : fichier GÉNÉRÉ par `mix lcars.sp.gen` depuis sp_builder/sp_blocks/. " <>
            "NE PAS ÉDITER (édite les blocs). Bloc ou rôle manquant → échec dur (no-fallback, cf. no-sp-no-pod-no-fleet). -->"

  @doc """
  Reads YAML from blocks_dir/sp-map.yaml without fallback or schema validation; read/parse errors raise.
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

  # audit!/2 treats any occurrence of this marker as generated, not only a first-line header.
  # It is an overwrite convention, not authenticated provenance.
  @generated_marker "GÉNÉRÉ par `mix lcars.sp.gen`"

  @doc """
  Raises with all detected role/map disagreements: a role with neither map entry nor draft,
  an unknown mapped role, or a mapped role with a draft lacking the generated marker.
  Unmapped roles with drafts and mapped roles with generated drafts are accepted.

  Draft lookup uses SPBuilder.sp_draft_path/1's default catalogue scope, not an explicit
  generation destination. Map values and block content are not validated here; generate!/3
  does not call this audit automatically.
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
  Writes one draft per map entry and returns sorted role names. With confined?: true, all
  targets use drafts_dir; otherwise an existing system draft receives its role's output.
  Does not create directories or run audit!/2. Writes overwrite and are not transactional:
  earlier drafts remain changed if a later entry fails. confined? selects the destination,
  not validation of role/block path segments.
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

  # Existing system drafts receive unconfined generation. Explicit-catalogue generation must
  # use confined? so an author's override does not overwrite the shipped system default.
  defp draft_target(drafts_dir, role) do
    file = "agent-#{role}-base.md"
    system = Path.join([Fleet.Catalogue.system_root(), "sp_builder/sp_drafts", file])

    if File.regular?(system), do: system, else: Path.join(drafts_dir, file)
  end

  # Keep business-over-system block precedence and name the resolved path on read errors.
  # With no matching file, Catalogue.find returns the expected business path for diagnosis.
  defp read_block!(role, block, blocks_dir) do
    path = Fleet.Catalogue.find(blocks_dir, Fleet.Catalogue.rel(:sp_blocks), block <> ".md")

    case File.read(path) do
      {:ok, content} ->
        content |> strip_leading_comment() |> String.trim_trailing()

      {:error, reason} ->
        raise "SP blocks: role #{role} — block `#{block}` unreadable (#{path}): #{inspect(reason)} (no-fallback)"
    end
  end

  # Removes any first HTML comment and surrounding whitespace, not only a Date header.
  defp strip_leading_comment(content), do: String.replace(content, ~r/\A\s*<!--.*?-->\s*/s, "")
end
