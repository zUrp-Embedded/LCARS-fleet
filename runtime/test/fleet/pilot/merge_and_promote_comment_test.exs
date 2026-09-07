defmodule Fleet.Pilot.MergeAndPromoteCommentTest do
  @moduledoc """
  The closing comment of a merge is the trace an operator reads months later. It must state what
  HAPPENED, not what the nominal path usually does.

  Measured 2026-08-04 on the bench (`hello-world#4`): a PR with ZERO review carried "the judges
  APPROVED the PR (native reviews)", under a line claiming "nothing is faked". The card
  (`workshop-direct`) declares no jury on purpose — the seal was correct, the sentence was not.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.MergeAndPromote

  describe "zero-judge card — the frequent, nominal case" do
    test "claims NO approval, and says on whose authority the merge happened" do
      body = MergeAndPromote.promote_comment(4, 5, "scribe", [])

      refute body =~ "APPROUVÉ"
      refute body =~ "APPROVED"
      assert body =~ "aucun juge"
      # The floor that DID run is named — an operator must not read "nobody validated" as
      # "nothing checked it".
      assert body =~ "provenance"
    end

    test "the branch-protection note is NOT printed — it would contradict the line above it" do
      body = MergeAndPromote.promote_comment(4, 5, "scribe", [])
      refute body =~ "EXIGE les approbations"
    end
  end

  describe "jury ILLISIBLE — la lecture forge a echoue, et ce n'est PAS un zero-juge" do
    # LE DEFAUT QUE CES DEUX TEMOINS FERMENT. `approving_judges/4` repliait tout echec de
    # `pr_review_state/3` sur `[]` — la meme valeur que « la carte ne pose aucun juge ». Une forge
    # qui tousse pendant le sceau faisait donc ecrire sur un ticket QUI A UN JURY que la carte n'en
    # pose aucun, et que c'est nominal, dans la seule piece qui atteste pourquoi ce merge etait
    # legitime.
    #
    # Aucun temoin ne pouvait le voir : ceux du zero-juge passent `[]` EN DUR, donc ils mesurent le
    # rendu, jamais la resolution. Les deux etats etaient indiscernables a l'entree de la fonction
    # testee.
    test "n'affirme AUCUN juge, garde ce qui est etabli, et nomme l'action possible" do
      body = MergeAndPromote.promote_comment(4, 5, "scribe", :unreadable)

      refute body =~ "aucun juge"
      refute body =~ "nominal"
      refute body =~ "APPROUVÉ"
      refute body =~ "APPROVED"

      assert body =~ "NON LU"
      assert body =~ "n'a pas pu être obtenu de la forge"
      # Ce qui EST etabli reste dit : le mur est une lecture independante.
      assert body =~ "provenance"
      # L'action possible, nommee — c'est la seule.
      assert body =~ "allez les lire sur la PR"
    end

    test "mur NON joue : le commentaire dit que RIEN n'atteste ce merge" do
      body = MergeAndPromote.promote_comment(4, 5, "scribe", :unreadable, {:skipped, :no_head})

      assert body =~ "NON LU"
      assert body =~ "n'a PAS tourné"
      assert body =~ "Rien n'atteste ce merge"
      refute body =~ "aucun juge"
    end

    test "la note de branch-protection ne s'imprime pas — on ignore s'il y avait des approbations a exiger" do
      body = MergeAndPromote.promote_comment(4, 5, "scribe", :unreadable)
      refute body =~ "EXIGE les approbations"
    end
  end

  describe "judged card" do
    test "names the accounts that actually approved" do
      body = MergeAndPromote.promote_comment(7, 9, "engineer", ["qualifier", "reviewer"])

      assert body =~ "`qualifier`"
      assert body =~ "`reviewer`"
      assert body =~ "APPROVED"
      refute body =~ "aucun juge"
    end

    test "keeps the interim branch-protection note where it is true" do
      body = MergeAndPromote.promote_comment(7, 9, "engineer", ["qualifier"])
      assert body =~ "EXIGE les approbations"
    end
  end

  describe "invariants shared by both paths" do
    test "the producer and the PR are named in every case" do
      for approvers <- [[], ["qualifier"]] do
        body = MergeAndPromote.promote_comment(42, 43, "scribe", approvers)
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
        MergeAndPromote.promote_comment(4, 5, "scribe", [], {:skipped, {:no_statement, "ref"}})

      refute body =~ "il a été franchi",
             "le sceau atteste un mur qui n'a pas tourne — et la note posee juste apres dit le " <>
               "contraire, sur le meme ticket"

      assert body =~ "n'a PAS tourné"
      assert body =~ "no_statement"
      assert body =~ "AUCUN contrôle mécanique"
    end

    test "TEMOIN — mur FRANCHI + zero juge → la phrase d'origine, inchangee" do
      body = MergeAndPromote.promote_comment(4, 5, "scribe", [], :ok)

      assert body =~ "il a été franchi"
      refute body =~ "n'a PAS tourné"
    end

    test "TEMOIN — avec des juges, la ligne parle des juges quel que soit le mur" do
      for wall <- [:ok, {:skipped, :no_local_clone}] do
        body = MergeAndPromote.promote_comment(7, 9, "engineer", ["qualifier"], wall)
        assert body =~ "review(s) **APPROVED** natives"
        refute body =~ "n'a PAS tourné"
      end
    end

    test "le defaut reste `:ok` — les appelants a quatre arguments ne changent pas de sens" do
      assert MergeAndPromote.promote_comment(4, 5, "scribe", []) ==
               MergeAndPromote.promote_comment(4, 5, "scribe", [], :ok)
    end
  end
end
