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
      # The card names both halves and nothing compared them. `engineer` produces AND sits on the
      # jury whose approvals gate the seal: it reviews the PR it opened, and its approval counts.
      # Every mechanism involved works exactly as written, so the pipeline reports a normal review
      # — there is no downstream signal that could tell this apart from a real one.
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
      # The guard keys on `brief_kind`, not on the step's position, and this is why. `gk-smoke`
      # runs a `reviewer` step with a soft gate AND carries `reviewer` in its jury: two different
      # acts on two different objects. A guard written on "the role appears as a step" would refuse
      # a shipped canon card at boot — a wall that fires on a correct configuration is worse than
      # the hole it closes, because the next person widens it until it stops firing.
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

  # THE KNOB IS GONE. `:fleet_pilot, :workshop_workflow_map` named the doc card globally, defaulting
  # to `"workshop-direct"` — one catalogue's card. One name cannot serve N catalogues, and the
  # catalogue serving a project is not the one that named the default. The rail is now resolved by
  # what a card IS: it carries a producer step on `face: workshop`.
  #
  # Two of the three regimes that function guarded existed only because a NAME can be wrong (dead
  # name, name pointing at an all-code card). A property cannot be wrong — it can only be absent, or
  # claimed twice, and those are the two tests below.
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

    @tag :tmp_dir
    test "DEUX cartes revendiquant le rail : le publish refuse, et il les NOMME", %{tmp_dir: tmp} do
      # Ce qui rend la resolution totale. Sans ce garde, `Enum.find` rendrait la premiere par ordre
      # alphabetique — un rail choisi par un tri, ce que personne n'a decide. Meme endroit et meme
      # raison que deux roles sur un `role_index` : le garde va la ou l'objet fusionne est enfin
      # visible.
      File.write!(Path.join(tmp, "atelier-un.yaml"), card_yaml("atelier-un", "workshop"))
      File.write!(Path.join(tmp, "atelier-deux.yaml"), card_yaml("atelier-deux", "workshop"))

      Fleet.TestEnv.put_env_restoring(:fleet_workflow, :workflow_maps_root, tmp)
      on_exit(&Fleet.Workflow.Loader.unpublish_all_images/0)

      err = assert_raise RuntimeError, fn -> Fleet.Workflow.Loader.publish_image!() end
      assert err.message =~ "atelier-deux, atelier-un"
      assert err.message =~ "One card per catalogue"
    end

    defp card_yaml(name, face) do
      """
      kind: WorkflowMap
      metadata:
        name: #{name}
        description: "carte de fixture"
        applicable_intensity: [C0]
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
