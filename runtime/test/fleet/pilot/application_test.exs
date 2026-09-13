defmodule Fleet.Pilot.ApplicationTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Application

  describe "validate_card_steps!/1 — every canon step role resolves at boot" do
    test "the real canon cards all resolve (no raise)" do
      # The shipped canon must boot clean: every step role of every card loads a cap-profile.
      assert :ok = Application.validate_card_steps!()
    end

    @tag :tmp_dir
    test "a step role that does not resolve raises fail-loud at boot", %{tmp_dir: tmp} do
      # Schema-valid card, but the step role is not a cap-profile. Without the boot check this
      # only surfaces at the first dispatch (CapProfile.resolve → :not_found = a stuck ticket).
      card = """
      kind: WorkflowMap
      metadata:
        name: bad-role
        description: "a step role that does not resolve"
        presentation: "test card — bad step role"
      spec:
        jury: [qualifier, reviewer]
        ci: ignore
        max_rework_rounds: 2
        steps:
          implement:
            role: nonexistent-role-xyz
            needs: []
            inputs:
              - ticket.body
            outputs:
              - deliverable
      """

      File.write!(Path.join(tmp, "bad-role.yaml"), card)

      assert_raise RuntimeError, ~r/does NOT resolve to a cap-profile/, fn ->
        Application.validate_card_steps!(workflow_maps_root: tmp)
      end
    end

    @tag :tmp_dir
    test "a PRODUCER sitting on its own card's jury raises — it would review its own PR", %{
      tmp_dir: tmp
    } do
      # A worker in both steps and jury would review its own work.
      File.write!(Path.join(tmp, "self-judge.yaml"), """
      kind: WorkflowMap
      metadata:
        name: self-judge
        description: "the producer is in its own jury"
        presentation: "test card — self judgement"
      spec:
        jury: [engineer, reviewer]
        ci: ignore
        max_rework_rounds: 2
        steps:
          implement:
            role: engineer
            needs: []
      """)

      err =
        assert_raise RuntimeError, fn ->
          Application.validate_card_steps!(workflow_maps_root: tmp)
        end

      assert err.message =~ "PRODUCES as"
      assert err.message =~ "own PR"
    end

    @tag :tmp_dir
    test "a JUDGE role that is also a step is LEGITIMATE — gk-smoke ships exactly that", %{
      tmp_dir: tmp
    } do
      # Judge roles may also be steps on different objects; appearance in steps
      # alone must not disqualify a juror.
      File.write!(Path.join(tmp, "judge-step.yaml"), """
      kind: WorkflowMap
      metadata:
        name: judge-step
        description: "a judge role also runs as a step"
        presentation: "test card — judge as step"
      spec:
        jury: [qualifier, reviewer]
        ci: ignore
        max_rework_rounds: 2
        steps:
          build:
            role: engineer
            needs: []
          review:
            role: reviewer
            needs: [build]
      """)

      assert :ok = Application.validate_card_steps!(workflow_maps_root: tmp)
    end
  end

  # Catalogue membership proves only the default's name. This guard explicitly
  # checks that the named card loads.
  describe "validate_default_card_loads!/1 — le default_card du catalogue doit CHARGER au boot" do
    test "le catalogue livre passe" do
      assert :ok = Application.validate_default_card_loads!()
    end

    @tag :tmp_dir
    test "un default_card qui ne CHARGE pas REFUSE le boot", %{tmp_dir: tmp} do
      # An existing but schema-invalid card passes a name-only membership check.
      File.write!(Path.join(tmp, "cassee.yaml"), """
      kind: WorkflowMap
      metadata:
        name: cassee
      spec: pas-un-objet
      """)

      File.write!(
        Path.join(tmp, "catalogue.yaml"),
        "api_version: 1\nname: cat\ndefault_card: cassee\n"
      )

      assert_raise RuntimeError, ~r/cassee/, fn ->
        Application.validate_default_card_loads!(workflow_maps_root: tmp, catalogue_root: tmp)
      end
    end

    @tag :tmp_dir
    test "un default_card valide passe — la garde CHARGE, elle n'interdit rien d'autre", %{
      tmp_dir: tmp
    } do
      File.write!(Path.join(tmp, "large.yaml"), """
      kind: WorkflowMap
      metadata:
        name: large
        description: "une carte de fixture qui charge"
      spec:
        jury: []
        ci: ignore
        max_rework_rounds: 1
        steps:
          build:
            role: engineer
            needs: []
      """)

      File.write!(
        Path.join(tmp, "catalogue.yaml"),
        "api_version: 1\nname: large\ndefault_card: large\n"
      )

      assert :ok =
               Application.validate_default_card_loads!(
                 workflow_maps_root: tmp,
                 catalogue_root: tmp
               )
    end
  end

  describe "le rail doc se resout par PROPRIETE, plus par un nom configure" do
    test "le canon livre resout son rail sans configuration" do
      assert Fleet.Workflow.Loader.workshop_card_name() == "workshop-direct"
      assert Fleet.Project.Roles.workshop_workflow_map() == "workshop-direct"
      assert :ok = Application.validate_workshop_card!()
    end

    @tag :tmp_dir
    test "aucune carte porteuse = pas de rail doc : bruyant, jamais un refus", %{tmp_dir: tmp} do
      # Un catalogue etroit (celui d'un operateur, une fixture) n'a legitimement pas de rail doc.
      # Refuser le boot la serait une politique que ce controle n'a pas mandat de poser.
      File.write!(Path.join(tmp, "all-code.yaml"), card_yaml("all-code", "code"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Application.validate_workshop_card!(workflow_maps_root: tmp)
        end)

      assert log =~ "no doc card"
      assert log =~ "face: workshop"
      assert Fleet.Workflow.Loader.workshop_card_name(workflow_maps_root: tmp) == nil
    end

    defp card_yaml(name, face) do
      """
      kind: WorkflowMap
      metadata:
        name: #{name}
        description: "carte de fixture"
      spec:
        jury: []
        ci: ignore
        max_rework_rounds: 1
        steps:
          build:
            role: engineer
            face: #{face}
            needs: []
            inputs:
              - ticket.body
      """
    end
  end
end
