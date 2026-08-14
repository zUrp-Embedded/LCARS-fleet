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

  # THE KNOB IS GONE. `:lcars_fleet, :pilot_workshop_workflow_map` named the doc card globally, defaulting
  # to `"workshop-direct"` — one catalogue's card. One name cannot serve N catalogues, and the
  # catalogue serving a project is not the one that named the default. The rail is now resolved by
  # what a card IS: it carries a producer step on `face: workshop`.
  #
  # Two of the three regimes that function guarded existed only because a NAME can be wrong (dead
  # name, name pointing at an all-code card). A property cannot be wrong — it can only be absent, or
  # claimed twice, and those are the two tests below.
  describe "validate_default_card_matrix!/1 — le defaut doit savoir servir le cas par defaut" do
    test "le catalogue livre passe" do
      assert :ok = Application.validate_default_card_matrix!()
    end

    @tag :tmp_dir
    test "un default_card hors matrice du niveau non-declare REFUSE le boot", %{tmp_dir: tmp} do
      # Le defaut du catalogue et le niveau qu'un projet prend quand personne ne declare sont, mis
      # ensemble, ce qu'un projet non declare RECOIT. Ils se contredisaient par ecrit — carte
      # `[C1..C4]`, niveau `C0` — et rien ne le disait : l'avertissement off-matrix ne regardait que
      # les surcharges explicites, et le controle de boot verifiait que la carte EXISTE, pas qu'elle
      # s'applique. Chaque projet non declare tournait sur une carte affirmant ne pas le couvrir.
      level = Fleet.Project.Intensity.undeclared_level()
      other = if level == "C0", do: "C4", else: "C0"

      File.write!(Path.join(tmp, "etroite.yaml"), """
      kind: WorkflowMap
      metadata:
        name: etroite
        description: "une carte qui ne couvre pas le niveau non-declare"
        applicable_intensity: [#{other}]
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
        "api_version: 1\nname: etroit\ndefault_card: etroite\n"
      )

      assert_raise RuntimeError, ~r/does NOT cover #{level}/, fn ->
        Application.validate_default_card_matrix!(workflow_maps_root: tmp, catalogue_root: tmp)
      end
    end

    @tag :tmp_dir
    test "une carte qui couvre le niveau passe — la garde borne, elle n'interdit pas", %{
      tmp_dir: tmp
    } do
      level = Fleet.Project.Intensity.undeclared_level()

      File.write!(Path.join(tmp, "large.yaml"), """
      kind: WorkflowMap
      metadata:
        name: large
        description: "une carte qui couvre le niveau non-declare"
        applicable_intensity: [#{level}]
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
               Application.validate_default_card_matrix!(
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
