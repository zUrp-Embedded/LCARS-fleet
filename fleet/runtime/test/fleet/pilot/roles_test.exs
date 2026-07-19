defmodule Fleet.Pilot.RolesTest do
  @moduledoc """
  Locks the single AUTHORITY for workshop roles (`Fleet.Pilot.Roles`): canonical defaults +
  opts overrides. `ProjectOnboard` and `GatekeeperSeal` delegate here (no default rewritten elsewhere).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Pilot.Roles

  test "producer_role: config default `engineer`, overridden by the opt" do
    assert "engineer" == Roles.producer_role()
    assert "designer" == Roles.producer_role(producer_role: "designer")
  end

  test "gatekeeper_role: config default `gatekeeper`, overridden by the opt" do
    assert "gatekeeper" == Roles.gatekeeper_role()
    assert "sentinel" == Roles.gatekeeper_role(gatekeeper_role: "sentinel")
  end

  test "jury: THE CARD is the source (default delegation card without a map in hand), opt = test seam" do
    # nil map → the delegation default card (brief-gate) is loaded and ITS jury returned.
    assert ["qualifier", "reviewer"] == Roles.jury(nil)
    # a loaded map in hand → its own jury, no card load.
    assert ["a", "b"] == Roles.jury(%{"jury" => ["a", "b"]})
    # injection seam (tests/hermetic overrides) — never a config.
    assert ["x"] == Roles.jury(nil, reviewer_roles: ["x"])
  end

  describe "project_jury/2 (jury of the PROJECT's declared card)" do
    @tag :tmp_dir
    test "declared card → ITS jury; a zero-judge card returns [] (deliberate)", %{tmp_dir: tmp} do
      proj = Path.join(tmp, "demo")
      File.mkdir_p!(proj)

      :ok =
        Fleet.Pilot.ProjectIntensity.write(proj,
          intensity_level: "C1",
          intensity_justification: "light card",
          workflow_map: "c1-light"
        )

      assert ["qualifier"] == Roles.project_jury("fleet/demo", projects_root: tmp)

      poc = Path.join(tmp, "poc")
      File.mkdir_p!(poc)

      :ok =
        Fleet.Pilot.ProjectIntensity.write(poc,
          intensity_level: "C0",
          intensity_justification: "throwaway",
          workflow_map: "c0-poc"
        )

      assert [] == Roles.project_jury("fleet/poc", projects_root: tmp)
    end

    @tag :tmp_dir
    test "undeclared project → the delegation default card's jury (quiet)", %{tmp_dir: tmp} do
      assert ["qualifier", "reviewer"] == Roles.project_jury("fleet/ghost", projects_root: tmp)
    end

    test "seam :reviewer_roles wins FIRST — no disk read under the seam" do
      assert ["x"] ==
               Roles.project_jury("fleet/any",
                 reviewer_roles: ["x"],
                 projects_root: "/nonexistent-root"
               )
    end

    @tag :tmp_dir
    test "declared card that no longer loads → LOUD fallback to the delegation default", %{
      tmp_dir: tmp
    } do
      proj = Path.join(tmp, "broken")
      File.mkdir_p!(proj)

      # The declaration writes even when the named card is unknown (creation is never walled
      # on a card typo) — the fallback happens LOUD at read time, here.
      capture_log(fn ->
        :ok =
          Fleet.Pilot.ProjectIntensity.write(proj,
            intensity_level: "C1",
            intensity_justification: "typo'd card",
            workflow_map: "ghost-card"
          )
      end)

      log =
        capture_log(fn ->
          assert ["qualifier", "reviewer"] == Roles.project_jury("fleet/broken", projects_root: tmp)
        end)

      assert log =~ "does not load"
    end
  end

  test "delegation_workflow_map: single accessor of the default card name" do
    assert "brief-gate" == Roles.delegation_workflow_map()
    assert "other" == Roles.delegation_workflow_map(delegation_workflow_map: "other")
  end

  test "GatekeeperSeal.gatekeeper_role/0 re-exports the authority (same value)" do
    assert Fleet.Pilot.GatekeeperSeal.gatekeeper_role() == Roles.gatekeeper_role()
  end

  test "the arch pod id is PER-PROJECT — the single authority is ProjectArchitect.pod_id_for/1" do
    # Reorg 2026-07-19: Roles.architect_pod_id (the "permanent-architect" singleton accessor) is GONE.
    refute function_exported?(Roles, :architect_pod_id, 1)
    assert Fleet.Pilot.ProjectArchitect.pod_id_for("fleet/demo") == "architect-demo"
    assert Fleet.Pilot.ProjectArchitect.pod_id_for("demo") == "architect-demo"
  end
end
