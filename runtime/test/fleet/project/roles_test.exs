defmodule Fleet.Project.RolesTest do
  @moduledoc """
  Exercises role resolution, overrides and project-card fallback.
  Incident stubs observe callback arguments, not durable storage; catalogue
  assertions describe the bundled profiles used by these tests.
  """
  # Mutates global pilot_producer_role; cleanup does not isolate concurrent readers.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Project.Declaration
  alias Fleet.Project.Roles

  test "producer_role: RESOLU par capability, jamais un litteral — et l'opt garde la main" do
    # The bundled catalogue has multiple producers; the unconfigured last resort must refuse.
    err = assert_raise RuntimeError, fn -> Roles.producer_role() end
    assert err.message =~ "scribe"
    assert err.message =~ "engineer"
    assert err.message =~ ":pilot_producer_role"

    # Les deux echappatoires designees, dans l'ordre de priorite : l'opt, puis la config deploy.
    assert "designer" == Roles.producer_role(producer_role: "designer")

    Application.put_env(:lcars_fleet, :pilot_producer_role, "engineer")
    on_exit(fn -> Application.delete_env(:lcars_fleet, :pilot_producer_role) end)
    assert "engineer" == Roles.producer_role()
  end

  test "gatekeeper_role: resolu par `exception_judge`, l'opt garde la main" do
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
        Declaration.write(proj,
          justification: "light card",
          workflow_map: "c1-light"
        )

      assert ["qualifier"] == Roles.project_jury("fleet/demo", code_root: tmp)

      poc = Path.join(tmp, "poc")
      File.mkdir_p!(poc)

      :ok =
        Declaration.write(poc,
          justification: "throwaway",
          workflow_map: "c0-poc"
        )

      assert [] == Roles.project_jury("fleet/poc", code_root: tmp)
    end

    @tag :tmp_dir
    test "undeclared project → the delegation default card's jury (quiet)", %{tmp_dir: tmp} do
      assert ["qualifier", "reviewer"] == Roles.project_jury("fleet/ghost", code_root: tmp)
    end

    test "seam :reviewer_roles wins FIRST — no disk read under the seam" do
      assert ["x"] ==
               Roles.project_jury("fleet/any",
                 reviewer_roles: ["x"],
                 code_root: "/nonexistent-root"
               )
    end

    @tag :tmp_dir
    test "declared card that no longer loads → LOUD fallback to the delegation default", %{
      tmp_dir: tmp
    } do
      proj = Path.join(tmp, "broken")
      File.mkdir_p!(proj)

      # Simulate a declaration whose card has since disappeared. write/2 now rejects
      # unknown explicit names, so this read-side fixture edits the saved record directly.
      :ok =
        Declaration.write(proj,
          justification: "card lost by the catalogue since",
          workflow_map: "standard-qa"
        )

      declaration_path = Path.join(proj, Fleet.Layout.project_declaration_file())

      declaration_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("pipeline_default", "ghost-card")
      |> Jason.encode!()
      |> then(&File.write!(declaration_path, &1))

      log =
        capture_log(fn ->
          assert ["qualifier", "reviewer"] ==
                   Roles.project_jury("fleet/broken", code_root: tmp)
        end)

      assert log =~ "does not load"
    end

    @tag :tmp_dir
    test "the card substitution records a durable INCIDENT (judgment-layer change, never a whisper)",
         %{tmp_dir: tmp} do
      proj = Path.join(tmp, "demo")
      File.mkdir_p!(proj)

      :ok =
        Declaration.write(proj,
          justification: "x",
          workflow_map: "standard-qa"
        )

      # Keep only the fallback card. The callback records the substitution attempt,
      # without running the durable incident consumer.
      maps = Path.join(tmp, "maps")
      File.mkdir_p!(maps)

      File.write!(Path.join(maps, "brief-gate.yaml"), """
      kind: WorkflowMap
      metadata:
        name: brief-gate
      spec:
        max_rework_rounds: 1
        jury: [qualifier]
        ci: ignore
        steps:
          only:
            role: engineer
      """)

      me = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ["qualifier"] ==
                   Roles.project_jury("fleet/demo",
                     code_root: tmp,
                     workflow_maps_root: maps,
                     incident_fun: fn op, subject, reason, opts ->
                       send(me, {:incident, op, subject, reason, opts})
                       :recorded
                     end
                   )
        end)

      assert_received {:incident, "card", "fleet/demo", :declared_card_unloadable, iopts}
      assert iopts[:reason_detail] =~ "standard-qa"
      assert log =~ "does not load"
    end
  end

  test "delegation_workflow_map: single accessor of the default card name" do
    assert "brief-gate" == Roles.delegation_workflow_map()
    assert "other" == Roles.delegation_workflow_map(delegation_workflow_map: "other")
  end

  test "MergeAndPromote.gatekeeper_role/0 re-exports the authority (same value)" do
    assert Fleet.Pilot.MergeAndPromote.gatekeeper_role() == Roles.gatekeeper_role()
  end

  describe "conflict_resolver_role/1 — its OWN capability, so the seal keeps its signatory" do
    test "the two responsibilities are held by DIFFERENT roles — and the test says the property" do
      # This compares current bundled holders; independent option resolution is tested below.
      refute Roles.conflict_resolver_role() == Roles.gatekeeper_role()
    end

    # Use options to avoid changing the global role seen by other consumers.
    test "MOVING the tier-2 resolver does NOT move the seal's signatory" do
      # Separate keys let the conflict executor change without changing the gatekeeper judge.
      signatory = Roles.gatekeeper_role()

      assert Roles.conflict_resolver_role(conflict_resolver_role: "engineer") == "engineer"
      assert Roles.gatekeeper_role() == signatory
      assert Fleet.Pilot.MergeAndPromote.gatekeeper_role() == signatory
    end

    test "and the reverse: moving the signatory does not move the resolver" do
      resolver = Roles.conflict_resolver_role()

      assert Roles.gatekeeper_role(gatekeeper_role: "scoper") == "scoper"
      assert Roles.conflict_resolver_role() == resolver
    end
  end

  test "the arch pod id is PER-PROJECT — the single authority is ProjectArchitect.pod_id_for/1" do
    # The removed fleet singleton accessor must not replace project-specific pod IDs.
    refute function_exported?(Roles, :architect_pod_id, 1)
    assert Fleet.Project.Architect.pod_id_for("fleet/demo") == "architect-demo"
    assert Fleet.Project.Architect.pod_id_for("demo") == "architect-demo"
  end
end
