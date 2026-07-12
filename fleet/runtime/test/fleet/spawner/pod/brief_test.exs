defmodule Fleet.Spawner.Pod.BriefTest do
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.Brief

  describe "issue_id_to_filename/1" do
    test "cas légitime Gitea (owner/name#N) : `/` → `_`, `#`/`-` gardés (inchangé vs l'ancien)" do
      assert Brief.issue_id_to_filename("fleet/lcars#600") == "fleet_lcars#600"
      assert Brief.issue_id_to_filename("issue-1") == "issue-1"
    end

    test "R1-35 : null byte / control / backslash neutralisés → `_` (plus de raise File.write, plus de séparateur)" do
      assert Brief.issue_id_to_filename("a\0b") == "a_b"
      assert Brief.issue_id_to_filename("a\nb\tc") == "a_b_c"
      assert Brief.issue_id_to_filename("a\\b") == "a_b"

      # tout `/` neutralisé → le résultat est TOUJOURS un leaf (aucune traversée de répertoire possible)
      refute Brief.issue_id_to_filename("../../etc/passwd") =~ "/"
    end
  end

  describe "enqueue_by_slot/3 — F-C035 (fail-closed sur slot invérifiable)" do
    test ":unknown (broker injoignable) → {:error, {:brief_slot_unknown, pod_id}}, PAS :ok (sinon pod idle sans brief)" do
      # Un admin.spawn n'a pas de dispatcher : maybe_enqueue_brief est le SEUL enqueue. Sur :unknown, retourner
      # :ok laissait le caller croire au succès → pod lancé idle (get_work_item = done:true), aucune réconciliation
      # ne ré-enqueue. Fail-closed : {:error} → le `with :projecting` échoue AVANT le launch → pod.failed → retry.
      state = %{
        pod_id: "admin-pod-x",
        issue_id: "tk-1",
        opts: [brief: "fais X"],
        cap_profile: nil
      }

      assert {:error, {:brief_slot_unknown, "admin-pod-x"}} =
               Brief.enqueue_by_slot(state, "fais X", :unknown)
    end

    test ":occupied → :ok (brief déjà en file au dispatch step, skip légitime silencieux)" do
      state = %{pod_id: "p", issue_id: "i", opts: [], cap_profile: nil}
      assert :ok = Brief.enqueue_by_slot(state, "fais X", :occupied)
    end
  end
end
