defmodule Fleet.Pilot.GatekeeperSealCommentTest do
  @moduledoc """
  The closing comment of a merge is the trace an operator reads months later. It must state what
  HAPPENED, not what the nominal path usually does.

  Measured 2026-08-04 on the bench (`hello-world#4`): a PR with ZERO review carried "the judges
  APPROVED the PR (native reviews)", under a line claiming "nothing is faked". The card
  (`workshop-direct`) declares no jury on purpose — the seal was correct, the sentence was not.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.GatekeeperSeal

  describe "zero-judge card — the frequent, nominal case" do
    test "claims NO approval, and says on whose authority the merge happened" do
      body = GatekeeperSeal.promote_comment(4, 5, "scribe", [])

      refute body =~ "APPROUVÉ"
      refute body =~ "APPROVED"
      assert body =~ "aucun juge"
      # The floor that DID run is named — an operator must not read "nobody validated" as
      # "nothing checked it".
      assert body =~ "provenance"
    end

    test "the branch-protection note is NOT printed — it would contradict the line above it" do
      body = GatekeeperSeal.promote_comment(4, 5, "scribe", [])
      refute body =~ "EXIGE les approbations"
    end
  end

  describe "judged card" do
    test "names the accounts that actually approved" do
      body = GatekeeperSeal.promote_comment(7, 9, "engineer", ["qualifier", "reviewer"])

      assert body =~ "`qualifier`"
      assert body =~ "`reviewer`"
      assert body =~ "APPROVED"
      refute body =~ "aucun juge"
    end

    test "keeps the interim branch-protection note where it is true" do
      body = GatekeeperSeal.promote_comment(7, 9, "engineer", ["qualifier"])
      assert body =~ "EXIGE les approbations"
    end
  end

  describe "invariants shared by both paths" do
    test "the producer and the PR are named in every case" do
      for approvers <- [[], ["qualifier"]] do
        body = GatekeeperSeal.promote_comment(42, 43, "scribe", approvers)
        assert body =~ "`scribe`"
        assert body =~ "PR #43"
        assert body =~ "Brique #42"
      end
    end
  end

  # JG-068 — « IL A ETE FRANCHI » ETAIT INCONDITIONNEL. Sur le chemin zero-juge, cette phrase est
  # TOUT ce qui atteste la legitimite du merge : la carte ne pose aucun juge, donc le plancher
  # mecanique est le dernier etage. Elle s'imprimait a l'identique que le mur ait tourne ou non.
  #
  # Le pire n'etait pas le silence mais la CONTRADICTION : la note « Provenance NON verifiee » posee
  # juste apres (BL-6-47.4) dit l'inverse, sur le meme ticket. Un operateur y trouvait deux phrases
  # opposees et aucune raison de preferer l'une.
  describe "JG-068 — la ligne de validation dit ce que le mur a fait" do
    test "mur SAUTE + zero juge → « n'a PAS tourne », jamais « franchi »" do
      body =
        GatekeeperSeal.promote_comment(4, 5, "scribe", [], {:skipped, {:no_statement, "ref"}})

      refute body =~ "il a été franchi",
             "le sceau atteste un mur qui n'a pas tourne — et la note posee juste apres dit le " <>
               "contraire, sur le meme ticket"

      assert body =~ "n'a PAS tourné"
      assert body =~ "no_statement"
      assert body =~ "AUCUN contrôle mécanique"
    end

    test "TEMOIN — mur FRANCHI + zero juge → la phrase d'origine, inchangee" do
      body = GatekeeperSeal.promote_comment(4, 5, "scribe", [], :ok)

      assert body =~ "il a été franchi"
      refute body =~ "n'a PAS tourné"
    end

    test "TEMOIN — avec des juges, la ligne parle des juges quel que soit le mur" do
      for wall <- [:ok, {:skipped, :no_local_clone}] do
        body = GatekeeperSeal.promote_comment(7, 9, "engineer", ["qualifier"], wall)
        assert body =~ "review(s) **APPROVED** natives"
        refute body =~ "n'a PAS tourné"
      end
    end

    test "le defaut reste `:ok` — les appelants a quatre arguments ne changent pas de sens" do
      assert GatekeeperSeal.promote_comment(4, 5, "scribe", []) ==
               GatekeeperSeal.promote_comment(4, 5, "scribe", [], :ok)
    end
  end
end
