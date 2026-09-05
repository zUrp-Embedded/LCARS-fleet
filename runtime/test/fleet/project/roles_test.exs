defmodule Fleet.Project.RolesTest do
  @moduledoc """
  Locks the single AUTHORITY for workshop roles (`Fleet.Project.Roles`): capability RESOLUTION +
  opts overrides. `ProjectOnboard` and `MergeAndPromote` delegate here (no literal rewritten elsewhere).
  """
  # `async: false` : ce fichier tient `:lcars_fleet, :pilot_producer_role` — une clé GLOBALE que le code de
  # production lit — pendant la durée d'un test. Il la nettoie bien (`on_exit` + `delete_env`), donc
  # il ne fuit pas ; mais tant qu'il la tient, `Roles.producer_role()` REND « engineer » au lieu de
  # LEVER, et n'importe quel test async concurrent qui traverse ce chemin voit l'autre réponse.
  # Même famille que la course `:pod_resolver` prouvée le 2026-08-06 : un app-env global ne se mute
  # pas depuis la phase concurrente.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fleet.Project.Roles

  test "producer_role: RESOLU par capability, jamais un litteral — et l'opt garde la main" do
    # Le catalogue declare DEUX producers depuis scribe (chantier face-projet 2026-08-02) : le
    # LAST-RESORT sans carte ni branche n'a plus de reponse honnete, et resolve_producer! REFUSE
    # par design (« a catalogue with eng_hw and eng_sw ») plutot que d'elire un producer au hasard.
    # Ce test epinglait `engineer` quand il etait seul ; il epingle desormais le refus — ET que le
    # message nomme les candidats, parce que c'est lui que l'operateur lira.
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
        Fleet.Project.Declaration.write(proj,
          justification: "light card",
          workflow_map: "c1-light"
        )

      assert ["qualifier"] == Roles.project_jury("fleet/demo", code_root: tmp)

      poc = Path.join(tmp, "poc")
      File.mkdir_p!(poc)

      :ok =
        Fleet.Project.Declaration.write(poc,
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

      # ⚠ CE TEST ECRIVAIT UNE CARTE INCONNUE A LA DECLARATION, en enoncant la politique
      # d'alors : « creation is never walled on a card typo — the fallback happens LOUD at read
      # time ». Cette politique tenait a une condition qui n'etait vraie qu'a MOITIE : elle
      # supposait que tout lecteur se rabat. `Roles` se rabat ; `StepDispatcher` charge en direct
      # et refuse d'onboarder, donc une issue sans route echouait a chaque tick, indefiniment,
      # sur un projet rendu `ready` (6-125). Un nom qu'on ne peut pas bruler est desormais REFUSE
      # a la declaration, et le refus nomme les cartes disponibles.
      #
      # L'etat teste ici reste donc REEL, et c'est le seul qui subsiste : la carte chargeait quand
      # elle a ete declaree, le catalogue l'a perdue depuis. On le fabrique en editant la
      # declaration ecrite, ce qui la garde schema-valide par construction.
      :ok =
        Fleet.Project.Declaration.write(proj,
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
        Fleet.Project.Declaration.write(proj,
          justification: "x",
          workflow_map: "standard-qa"
        )

      # A tmp catalogue holding ONLY the fallback card: the DECLARED one (standard-qa) no
      # longer loads, the never-stall fallback swaps the judgment layer — the swap must
      # land in the incident rail (the fallback card itself still loads: never-stall held).
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
      # This asserted `== "gatekeeper"` while the two costumes shared a role. That was a CATALOGUE
      # fact and the assertion pinned it as if it were a law, so it reddened the day the catalogue
      # moved — which is exactly what the split was built to allow.
      #
      # What is worth pinning is that the two keys resolve INDEPENDENTLY. The incumbents are read
      # from the catalogue, not restated here.
      refute Roles.conflict_resolver_role() == Roles.gatekeeper_role()
    end

    # Substitution through the OPT, never `Application.put_env`. The env is a NODE-WIDE table: in an
    # async file, posting `:gatekeeper_role` there is read by every concurrent test that seals a PR,
    # which then resolves a role whose forge token does not exist — `:role_token_unavailable`, on a
    # test that touched none of this. Measured, at the cost of a diagnosis: 0/4/5/7 failures
    # depending on the run, in two other files. The opt is process-local and proves the same thing,
    # which is why it is the accessor's FIRST precedence level.
    test "MOVING the tier-2 resolver does NOT move the seal's signatory" do
      # THE property of the item. Under one shared key, substituting the role that resolves an
      # exhausted conflict would also have substituted the role that SIGNS the merge — silently,
      # because nothing would have said the two decisions were the same decision.
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
    # Reorg 2026-07-19: Roles.architect_pod_id (the "permanent-architect" singleton accessor) is GONE.
    refute function_exported?(Roles, :architect_pod_id, 1)
    assert Fleet.Project.Architect.pod_id_for("fleet/demo") == "architect-demo"
    assert Fleet.Project.Architect.pod_id_for("demo") == "architect-demo"
  end
end
