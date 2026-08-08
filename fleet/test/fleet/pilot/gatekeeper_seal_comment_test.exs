defmodule Fleet.Pilot.GatekeeperSealCommentTest do
  @moduledoc """
  The closing comment of a merge is the trace an operator reads months later. It must state what
  HAPPENED, not what the nominal path usually does.

  Measured 2026-08-04 on the bench (`hello-world#4`): a PR with ZERO review carried "the judges
  APPROVED the PR (native reviews)", under a line claiming "nothing is faked". The card
  (`doc-direct`) declares no jury on purpose — the seal was correct, the sentence was not.
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
end
