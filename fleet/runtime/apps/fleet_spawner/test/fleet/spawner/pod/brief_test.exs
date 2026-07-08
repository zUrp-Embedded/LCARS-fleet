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
end
