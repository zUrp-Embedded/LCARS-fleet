defmodule Fleet.Pipeline.ModopsConsumptionTest do
  @moduledoc """
  Lot 6 inc2 — conformance LÉGÈRE : fleet_pipeline consomme les data V2
  (9 modop-bundles SP + 3 subagent-templates + refs `profile` des
  pipelines v2.5 résolvent vers des cap-profiles existants).

  Pas de sur-schématisation : les modop-bundles sont des fragments SP
  markdown (@import SPBuilder chantier-2), PAS du JSON config. Le schema
  structuré (modop-profile.json) valide le profile.yaml overlay, déjà
  matérialisé chantier-N. Ici on vérifie présence + bonne forme +
  cohérence des références pipeline→profile (l'invariant "fleet_pipeline
  consomme" du plan §Lot 6). `async: true`.
  """
  use ExUnit.Case, async: true

  # R0.8-brick6 : canon réabsorbé in-repo. modop-bundles + subagent-templates +
  # pipelines vivent dans `apps/fleet_pipeline/priv/canon/` ; cap-profiles dans
  # `apps/fleet_cap_profile/priv/canon/cap-profiles/` (R0.7). Pattern identique
  # brick1 MonkTest + brick5 PermanentBootTest (Application.app_dir).
  @canon Application.app_dir(:fleet_pipeline, "priv/canon")
  @cap_profiles Application.app_dir(:fleet_cap_profile, "priv/canon/cap-profiles")

  @bundles ~w(archive-mode brainstorming dual-review fire-mode long-session-discipline
              persuasion-discipline rubber-duck subagent-driven tdd)
  @subagent_templates ~w(subagent-code-quality-reviewer subagent-implementer
                         subagent-spec-reviewer)

  test "9 modop-bundles présents avec sp.md bien formé (header GO-7 + non-vide)" do
    for b <- @bundles do
      sp = Path.join([@canon, "modop-bundles", b, "sp.md"])
      assert File.exists?(sp), "modop-bundle absent: #{sp}"
      content = File.read!(sp)
      assert byte_size(content) > 200, "#{b}/sp.md trop court (non-formé ?)"
      assert content =~ ~r/^#\s/, "#{b}/sp.md sans titre markdown"
      assert content =~ "Statut", "#{b}/sp.md sans header Statut (GO-7)"
    end
  end

  test "3 subagent-templates présents + bien formés" do
    for t <- @subagent_templates do
      f = Path.join([@canon, "subagent-templates", "#{t}.md"])
      assert File.exists?(f), "subagent-template absent: #{f}"
      c = File.read!(f)
      assert byte_size(c) > 150 and c =~ ~r/^#\s/, "#{t}.md non-formé"
    end
  end

  test "refs `profile` des pipelines v2.5 résolvent vers cap-profiles existants" do
    for pname <- ["standard-qa", "audit-only"] do
      pipe = YamlElixir.read_from_file!(Path.join([@canon, "pipelines", "#{pname}.yaml"]))
      stages = get_in(pipe, ["spec", "stages"])

      for {sname, spec} <- stages do
        profile = spec["profile"]

        assert is_binary(profile) and profile != "",
               "#{pname}/#{sname} : profile manquant"

        cp_path = Path.join(@cap_profiles, profile)

        assert File.exists?(cp_path),
               "#{pname}/#{sname} : profile #{profile} introuvable dans 05_data-canon/cap-profiles/"
      end
    end
  end

  test "catalogue modop-bundles == 9 exact (pas de bundle orphelin/manquant)" do
    dirs =
      Path.join([@canon, "modop-bundles"])
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join([@canon, "modop-bundles", &1])))
      |> Enum.sort()

    assert dirs == Enum.sort(@bundles),
           "drift catalogue modop-bundles : #{inspect(dirs)} ≠ #{inspect(Enum.sort(@bundles))}"
  end
end
