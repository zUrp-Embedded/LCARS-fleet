defmodule Fleet.SPBuilder.Blocks do
  @moduledoc """
  Block-based composition of per-role system prompts. Source: `priv/sp_blocks/` (`core/*`, `method/*`,
  `role/*`) + the `sp-map.yaml` map (role → ORDERED block list; `role/*` last). The generator
  (`mix lcars.sp.gen`) writes `priv/sp_drafts/agent-<role>-base.md` — the flat draft that
  `Fleet.Spawner.Pod.Assets` reads and injects (N2). Split = debuggable + a single source of truth.

  Ring boundary: the SP is an APPLICATIVE primitive (it consumes the Ring 0 cap-profile → it lives at
  Ring 1, here). It carries ONLY Ring 0/1 invariants. Anything Ring 2+ (the `gate-decision-v1` vocabulary,
  the contract schema, the forge model) is NOT in the SP: it reaches the pod through the BRIEF (assembled
  higher up, `fleet_pilot`/`GateBrief`), single source. An SP block never duplicates the authority of a
  higher ring.

  HARD RULE (no-fallback, cf. memory `no-sp-no-pod-no-fleet`): a role with no blocks, or a listed block
  absent from disk → `compose!/3` RAISES. No SP → no pod → no fleet; never a silent degradation.
  """

  # `Date:` up front → satisfies the GO-7 hook (`<!--\s*Date\s*:`) without polluting the SP with a visible
  # markdown header. STATIC date (not `Date.utc_today`): generation must stay deterministic (the no-drift
  # test compares the committed flat to a regeneration — a dynamic date would break it the next day). The
  # header text stays FR: it is SP-file content (pod-facing convention).
  @header "<!-- Date: 2026-07-08 — SP v2 : fichier GÉNÉRÉ par `mix lcars.sp.gen` depuis priv/sp_blocks/. " <>
            "NE PAS ÉDITER (édite les blocs). Bloc ou rôle manquant → échec dur (no-fallback, cf. no-sp-no-pod-no-fleet). -->"

  @doc "Role → ordered block list, read from `<blocks_dir>/sp-map.yaml`."
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
      File.write!(
        Path.join(drafts_dir, "agent-#{role}-base.md"),
        compose!(role, blocks, blocks_dir)
      )

      role
    end)
    |> Enum.sort()
  end

  defp read_block!(role, block, blocks_dir) do
    path = Path.join(blocks_dir, block <> ".md")

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
