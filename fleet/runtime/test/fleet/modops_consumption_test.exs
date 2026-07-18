defmodule Fleet.Workflow.ModopsConsumptionTest do
  @moduledoc """
  LIGHT conformance: fleet_workflow consumes the V2 data
  (9 SP modop-bundles + 3 subagent-templates + `profile` refs of the
  v2.5 pipelines resolve to existing cap-profiles).

  No over-schematization: modop-bundles are markdown SP fragments
  (SPBuilder @import), NOT JSON config. The structured schema
  (modop-profile.json) validates the profile.yaml overlay. Here we check
  presence + well-formedness + consistency of the pipeline→profile
  references (the "fleet_workflow consumes" invariant). `async: true`.
  """
  use ExUnit.Case, async: true

  # R0.8-brick6: canon reabsorbed in-repo. The `workflow_maps` live in
  # `priv/workflow/canon/`; the modop-bundles + subagent-templates live
  # (F-C146/PORT) in `priv/cap_profile/canon/` (co-located with the overlay profiles +
  # reachable by SPBuilder); cap-profiles in
  # `priv/cap_profile/canon/cap-profiles/` (R0.7). app_dir pattern (brick1/brick5).
  @canon Application.app_dir(:lcars_fleet, "priv/workflow/canon")
  @modop_canon Application.app_dir(:lcars_fleet, "priv/cap_profile/canon")
  @cap_profiles Application.app_dir(:lcars_fleet, "priv/cap_profile/canon/cap-profiles")

  @bundles ~w(archive-mode brainstorming dual-review fire-mode long-session-discipline
              persuasion-discipline rubber-duck subagent-driven tdd)
  @subagent_templates ~w(subagent-code-quality-reviewer subagent-implementer
                         subagent-spec-reviewer)

  test "9 modop-bundles present with well-formed sp.md (GO-7 header + non-empty)" do
    for b <- @bundles do
      sp = Path.join([@modop_canon, "modop-bundles", b, "sp.md"])
      assert File.exists?(sp), "missing modop-bundle: #{sp}"
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

  test "`profile` refs of the v2.5 pipelines resolve to existing cap-profiles" do
    for pname <- ["standard-qa", "audit-only", "brief-gate"] do
      pipe = YamlElixir.read_from_file!(Path.join([@canon, "workflow_maps", "#{pname}.yaml"]))
      steps = get_in(pipe, ["spec", "steps"])

      for {sname, spec} <- steps do
        profile = spec["profile"]

        assert is_binary(profile) and profile != "",
               "#{pname}/#{sname}: missing profile"

        cp_path = Path.join(@cap_profiles, profile)

        assert File.exists?(cp_path),
               "#{pname}/#{sname}: profile #{profile} not found (#{cp_path})"
      end
    end
  end

  test "modop-bundles catalogue == exactly 9 (no orphan/missing bundle)" do
    dirs =
      Path.join([@modop_canon, "modop-bundles"])
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join([@modop_canon, "modop-bundles", &1])))
      |> Enum.sort()

    assert dirs == Enum.sort(@bundles),
           "modop-bundles catalogue drift: #{inspect(dirs)} ≠ #{inspect(Enum.sort(@bundles))}"
  end
end
