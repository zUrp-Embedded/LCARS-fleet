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
  end
end
