defmodule Fleet.SPBuilder.Blocks do
  @moduledoc """
  Composition des SP de rôle **par blocs**. Source : `priv/sp_blocks/` (`core/*`, `method/*`, `role/*`) +
  carte `sp-map.yaml` (rôle → liste ORDONNÉE de blocs ; `role/*` en dernier). Le générateur
  (`mix lcars.sp.gen`) écrit `priv/sp_drafts/agent-<role>-base.md` — le flat que `Fleet.Spawner.Pod.Assets`
  lit et injecte (N2). Découpé = debuggable + une source unique.

  Frontière de ring : le SP est une **primitive applicative** (il consomme la cap-profile Ring 0 → il vit
  Ring 1, ici). Il ne porte QUE des invariants Ring 0/1. Tout ce qui est Ring 2+ (vocab `gate-decision-v1`,
  schéma de contrat, modèle forge) N'EST PAS dans le SP : il arrive au pod par le **brief** (assemblé en haut,
  `fleet_pilot`/`GateBrief`), source unique. Un bloc SP ne duplique jamais une autorité d'un ring supérieur.

  RÈGLE DURE (no-fallback, cf. mémoire `no-sp-no-pod-no-fleet`) : rôle sans blocs, ou bloc listé absent du
  disque → `compose!/3` **LÈVE**. Pas de SP → pas de pod → pas de fleet ; on ne dégrade jamais en silence.
  """

  # `Date:` en tête → satisfait le hook GO-7 (`<!--\s*Date\s*:`) sans polluer le SP d'un header markdown
  # visible. Date STATIQUE (pas `Date.utc_today`) : la génération doit rester déterministe (le test no-drift
  # compare le flat committé à la re-génération — une date dynamique le casserait le lendemain).
  @header "<!-- Date: 2026-07-08 — SP v2 : fichier GÉNÉRÉ par `mix lcars.sp.gen` depuis priv/sp_blocks/. " <>
            "NE PAS ÉDITER (édite les blocs). Bloc ou rôle manquant → échec dur (no-fallback, cf. no-sp-no-pod-no-fleet). -->"

  @doc "Carte rôle → liste ordonnée de blocs, lue de `<blocks_dir>/sp-map.yaml`."
  @spec role_map(Path.t()) :: %{String.t() => [String.t()]}
  def role_map(blocks_dir) do
    blocks_dir |> Path.join("sp-map.yaml") |> YamlElixir.read_from_file!()
  end

  @doc "SP composé d'un rôle. Fail-loud si un bloc listé manque, ou si la liste est vide."
  @spec compose!(String.t(), [String.t()], Path.t()) :: String.t()
  def compose!(role, blocks, blocks_dir) when is_binary(role) and is_list(blocks) and blocks != [] do
    body = Enum.map_join(blocks, "\n\n", &read_block!(role, &1, blocks_dir))
    Enum.join([@header, "# System Prompt — #{role}", body], "\n\n") <> "\n"
  end

  def compose!(role, _blocks, _dir),
    do: raise("SP blocks: rôle #{inspect(role)} sans blocs dans sp-map.yaml (no-fallback : pas de SP → pas de pod)")

  @doc """
  Génère TOUS les flats `agent-<role>-base.md` de la carte, dans `drafts_dir`. Retourne les rôles générés.
  """
  @spec generate!(Path.t(), Path.t()) :: [String.t()]
  def generate!(blocks_dir, drafts_dir) do
    blocks_dir
    |> role_map()
    |> Enum.map(fn {role, blocks} ->
      File.write!(Path.join(drafts_dir, "agent-#{role}-base.md"), compose!(role, blocks, blocks_dir))
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
        raise "SP blocks: rôle #{role} — bloc `#{block}` illisible (#{path}) : #{inspect(reason)} (no-fallback)"
    end
  end

  # Retire le header HTML `<!-- Date: … -->` en tête de bloc (posé UNIQUEMENT pour satisfaire GO-7 sur le
  # fichier source) → il n'atteint jamais le SP composé, zéro pollution.
  defp strip_leading_comment(content), do: String.replace(content, ~r/\A\s*<!--.*?-->\s*/s, "")
end
