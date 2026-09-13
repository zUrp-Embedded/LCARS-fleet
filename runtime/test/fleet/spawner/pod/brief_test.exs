defmodule Fleet.Spawner.Pod.BriefTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.Brief

  describe "issue_id_to_filename/1" do
    test "legitimate Gitea case (owner/name#N): `/` → `_`, `#`/`-` kept" do
      assert Brief.issue_id_to_filename("fleet/lcars#600") == "fleet_lcars#600"
      assert Brief.issue_id_to_filename("issue-1") == "issue-1"
    end

    test "R1-35: null byte / control / backslash neutralized → `_` (no File.write raise, no separator)" do
      assert Brief.issue_id_to_filename("a\0b") == "a_b"
      assert Brief.issue_id_to_filename("a\nb\tc") == "a_b_c"
      assert Brief.issue_id_to_filename("a\\b") == "a_b"

      refute Brief.issue_id_to_filename("../../etc/passwd") =~ "/"
    end
  end

  describe "enqueue_by_slot/3 — F-C035 (fail-closed on unverifiable slot)" do
    test ":unknown (broker unreachable) → {:error, {:brief_slot_unknown, pod_id}}, NOT :ok (else idle pod without brief)" do
      # Admin spawn has no dispatcher to enqueue later; an unverifiable slot must fail before launch.
      state = %{
        pod_id: "admin-pod-x",
        issue_id: "tk-1",
        opts: [brief: "fais X"],
        cap_profile: nil
      }

      assert {:error, {:brief_slot_unknown, "admin-pod-x"}} =
               Brief.enqueue_by_slot(state, "fais X", :unknown)
    end

    test ":occupied → :ok (brief already queued at dispatch step, legitimate silent skip)" do
      state = %{pod_id: "p", issue_id: "i", opts: [], cap_profile: nil}
      assert :ok = Brief.enqueue_by_slot(state, "fais X", :occupied)
    end
  end
end
