defmodule Fleet.Workflow.ModopsConsumptionTest do
  @moduledoc """
  CONSUMER-INTEGRITY conformance of the SP modop-bundles + subagent-templates.

  modop-bundles are markdown SP fragments (SPBuilder @import), NOT JSON config. The old
  catalogue check pinned the bundle set by COUNT (== 9) + size — vacuous: it neither proved a
  bundle is CONSUMABLE nor caught a cap-profile referencing a missing one. It is replaced by
  two load-bearing checks computed from the real consumers (the cap-profiles' `modop_set`):
  every referenced bundle EXISTS (no dangling activation), and every existing bundle is either
  activated by a cap-profile or an EXPLICITLY-named `@known_orphans`. Well-formedness (GO-7
  header, non-empty) is checked on whatever bundles actually exist. `async: true`.

  The orphan-bundle CONTENT cleanup (fossilized architecture in their `sp.md`) rides with the
  SP-package rewrite — never edited by an agent alone; here we only pin the mechanical fact.
  """
  use ExUnit.Case, async: true

  # R0.8-brick6: canon reabsorbed in-repo. The `workflow_maps` live in
  # `priv/catalogue/workflow/canon/`; the modop-bundles + subagent-templates live
  # (F-C146/PORT) in `priv/catalogue/cap_profile/canon/` (co-located with the overlay profiles +
  # reachable by SPBuilder); cap-profiles in
  # `priv/catalogue/cap_profile/canon/cap-profiles/` (R0.7). app_dir pattern (brick1/brick5).
  # LES DEUX racines depuis le decoupage systeme/metier : un modop declare par un role mecanique
  # vit avec lui. Enumerer la seule racine metier compterait les bundles systeme comme absents et
  # les modops systeme comme des references pendantes — le test mesurerait une moitie de fleet.
  @modop_canons [
    Application.app_dir(:lcars_fleet, "priv/catalogue-system/cap_profile/canon"),
    Application.app_dir(:lcars_fleet, "priv/catalogue/cap_profile/canon")
  ]

  # ⚖ USER 2026-08-19 — SORTIE DE SUPERPOWERS : les trois templates (spec-reviewer,
  # code-quality-reviewer, implementer) ont été supprimés avec les déclarations qui les
  # activaient. Le corpus est VIDE et c'est la forme correcte, pas une perte.
  # La propriété tenue par ce test change donc de nature : elle n'épingle plus une LISTE
  # (qui serait un inventaire à maintenir à la main, et qui a déjà menti une fois — la
  # notice tierce en annonçait neuf pour huit) mais un INVARIANT : tout template PRÉSENT
  # est bien formé. Un corpus vide le satisfait ; un template ajouté demain est vérifié
  # sans que personne ait à penser à l'inscrire ici.
  @subagent_templates []

  # KNOWN orphan bundles: they EXIST but no canon cap-profile references them in its
  # `modop_set` (default/optional), so nothing can activate them. Their `sp.md` content also
  # describes a retired architecture — but the CONTENT cleanup rides with the SP-package rewrite
  # (never edited by an agent alone); this test only pins the MECHANICAL fact "which bundles have
  # no consumer", explicitly and by NAME, so a NEW orphan (a bundle added without a consumer)
  # fails instead of being silently absorbed by a presence/size count. Shrinking this list = the
  # SP chantier removing the fossil; growing it must be a conscious, named act.
  # `persuasion-discipline` a QUITTÉ cette liste le 2026-08-19 : il n'est plus orphelin, il
  # n'existe plus (sortie de superpowers). Rétrécir cette liste est l'acte conscient que le
  # commentaire ci-dessus réclame.
  @known_orphans ~w(archive-mode fire-mode)

  defp bundle_dirs, do: Enum.map(@modop_canons, &Path.join(&1, "modop-bundles"))

  defp existing_bundles do
    bundle_dirs()
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      dir |> File.ls!() |> Enum.filter(&File.dir?(Path.join(dir, &1)))
    end)
    |> Enum.sort()
  end

  # Bundles ACTIVABLE by the canon = the union of every cap-profile's modop_set default ∪ optional.
  # Computed from the cap-profiles themselves (the real consumers), never a hardcoded list.
  defp referenced_bundles do
    @modop_canons
    |> Enum.flat_map(&Path.wildcard(Path.join([&1, "cap-profiles", "*.yaml"])))
    |> Enum.flat_map(fn f ->
      case YamlElixir.read_from_file(f) do
        {:ok, %{"spec" => %{"modop_set" => set}}} when is_map(set) ->
          (Map.get(set, "default", []) || []) ++ (Map.get(set, "optional", []) || [])

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "every EXISTING modop-bundle has a well-formed sp.md (GO-7 header + non-empty)" do
    for b <- existing_bundles() do
      sp = Enum.find(bundle_dirs(), &File.exists?(Path.join([&1, b, "sp.md"])))
      assert sp, "missing modop-bundle sp.md: #{b}"
      content = File.read!(Path.join([sp, b, "sp.md"]))
      assert byte_size(content) > 200, "#{b}/sp.md too short (malformed?)"
      assert content =~ ~r/^#\s/, "#{b}/sp.md without markdown title"
      # "Statut" is the FR header of the SP fragments (SP content is FR by design).
      assert content =~ "Statut", "#{b}/sp.md without Statut header (GO-7)"
    end
  end

  test "tout subagent-template PRÉSENT est bien formé (corpus vide accepté)" do
    présents =
      Enum.flat_map(@modop_canons, fn r ->
        Path.wildcard(Path.join([r, "subagent-templates", "subagent-*.md"]))
      end)

    assert présents == [] or @subagent_templates != [],
           "des templates existent sur disque alors que la liste attendue est vide : " <>
             "la sortie de superpowers a été partiellement défaite, ou un template est revenu " <>
             "sans que personne le déclare — #{inspect(présents)}"

    for f <- présents do
      c = File.read!(f)
      assert byte_size(c) > 150 and c =~ ~r/^#\s/, "#{Path.basename(f)} malformed"
    end
  end

  test "consumer integrity: every bundle a cap-profile REFERENCES actually exists (no dangling activation)" do
    existing = MapSet.new(existing_bundles())
    dangling = Enum.reject(referenced_bundles(), &MapSet.member?(existing, &1))

    assert dangling == [],
           "cap-profiles reference modop-bundles that do NOT exist (a spawn would fail to compose): #{inspect(dangling)}"
  end

  test "consumer integrity: an EXISTING bundle is either activated by a cap-profile or a KNOWN orphan" do
    referenced = MapSet.new(referenced_bundles())
    orphans = existing_bundles() |> Enum.reject(&MapSet.member?(referenced, &1)) |> Enum.sort()

    # A bundle with no consumer must be an EXPLICITLY-named known orphan — never silently present.
    assert orphans == Enum.sort(@known_orphans),
           "orphan-bundle drift: #{inspect(orphans)} ≠ known #{inspect(Enum.sort(@known_orphans))}. " <>
             "A new activable bundle must have a cap-profile consumer; a removed orphan updates @known_orphans."
  end
end
