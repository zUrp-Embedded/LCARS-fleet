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
  @modop_canon Application.app_dir(:lcars_fleet, "priv/catalogue/cap_profile/canon")

  @subagent_templates ~w(subagent-code-quality-reviewer subagent-implementer
                         subagent-spec-reviewer)

  # KNOWN orphan bundles: they EXIST but no canon cap-profile references them in its
  # `modop_set` (default/optional), so nothing can activate them. Their `sp.md` content also
  # describes a retired architecture — but the CONTENT cleanup rides with the SP-package rewrite
  # (never edited by an agent alone); this test only pins the MECHANICAL fact "which bundles have
  # no consumer", explicitly and by NAME, so a NEW orphan (a bundle added without a consumer)
  # fails instead of being silently absorbed by a presence/size count. Shrinking this list = the
  # SP chantier removing the fossil; growing it must be a conscious, named act.
  @known_orphans ~w(archive-mode fire-mode persuasion-discipline)

  defp bundle_dir, do: Path.join(@modop_canon, "modop-bundles")

  defp existing_bundles do
    bundle_dir()
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(bundle_dir(), &1)))
    |> Enum.sort()
  end

  # Bundles ACTIVABLE by the canon = the union of every cap-profile's modop_set default ∪ optional.
  # Computed from the cap-profiles themselves (the real consumers), never a hardcoded list.
  defp referenced_bundles do
    Path.join([@modop_canon, "cap-profiles", "*.yaml"])
    |> Path.wildcard()
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
      sp = Path.join([bundle_dir(), b, "sp.md"])
      assert File.exists?(sp), "missing modop-bundle sp.md: #{sp}"
      content = File.read!(sp)
      assert byte_size(content) > 200, "#{b}/sp.md too short (malformed?)"
      assert content =~ ~r/^#\s/, "#{b}/sp.md without markdown title"
      # "Statut" is the FR header of the SP fragments (SP content is FR by design).
      assert content =~ "Statut", "#{b}/sp.md without Statut header (GO-7)"
    end
  end

  test "3 subagent-templates present + well-formed" do
    for t <- @subagent_templates do
      f = Path.join([@modop_canon, "subagent-templates", "#{t}.md"])
      assert File.exists?(f), "missing subagent-template: #{f}"
      c = File.read!(f)
      assert byte_size(c) > 150 and c =~ ~r/^#\s/, "#{t}.md malformed"
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
