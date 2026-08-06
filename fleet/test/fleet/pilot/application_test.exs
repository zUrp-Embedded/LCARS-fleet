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

  # Interim brake (IPC consultant 2026-08-02): the :ops_workflow_map knob names the card every
  # `genre/ops` ticket burns, and nothing checked that the name resolves to a card that can serve
  # a doc ticket — a dead name or an all-code-face card failed at the FIRST doc ticket, silently.
  describe "validate_ops_card!/1 — the ops knob resolves to a card that can serve a doc ticket" do
    test "the shipped canon passes (ops-direct carries its face: ops producer)" do
      assert :ok = Application.validate_ops_card!()
    end

    @tag :tmp_dir
    test "a knob EXPLICITLY set to a dead name raises with the operator's diagnosis",
         %{tmp_dir: tmp} do
      assert_raise RuntimeError, ~r/ops card "no-such-card" .*does NOT load/s, fn ->
        Application.validate_ops_card!(
          workflow_maps_root: tmp,
          ops_workflow_map: "no-such-card"
        )
      end
    end

    @tag :tmp_dir
    test "no ops card + knob at its DEFAULT = a catalogue with no doc rail: LOUD, never a refusal",
         %{tmp_dir: tmp} do
      # A narrow catalogue (an operator's own, a fixture) legitimately has no doc rail. Refusing
      # the boot there would be a policy this check has no mandate to set — it names what such a
      # deployment cannot do instead.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Application.validate_ops_card!(workflow_maps_root: tmp)
        end)

      assert log =~ "no ops card in this catalogue"
      assert log =~ "would wedge at dispatch"
    end

    @tag :tmp_dir
    test "a card with NO producer on face: ops raises — the doc ticket would build on the code face",
         %{tmp_dir: tmp} do
      card = """
      kind: WorkflowMap
      metadata:
        name: all-code
        description: "a card whose steps all sit on the code face"
        presentation: "test card — no ops face"
      spec:
        jury: [qualifier, reviewer]
        max_rework_rounds: 2
        steps:
          implement:
            role: engineer
            needs: []
            inputs:
              - ticket.body
            outputs:
              - deliverable
      """

      File.write!(Path.join(tmp, "all-code.yaml"), card)

      assert_raise RuntimeError, ~r/carries NO producer step on `face: ops`/, fn ->
        Application.validate_ops_card!(workflow_maps_root: tmp, ops_workflow_map: "all-code")
      end
    end
  end
end
