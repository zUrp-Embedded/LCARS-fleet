defmodule Fleet.Forge.ProtocolTest do
  use ExUnit.Case, async: true

  alias Fleet.Forge.PayloadFixture

  # Pure format examples; round-trips cover selected valid inputs, not all builder arguments.
  alias Fleet.Forge.Protocol, as: ForgeProtocol

  doctest Fleet.Forge.Protocol

  describe "feature_branch/2 + parse_feature_branch/1 (build+parse co-located)" do
    test "parse_feature_branch extracts {issue, role} from a system branch" do
      assert {:ok, {42, "engineer"}} =
               ForgeProtocol.parse_feature_branch("lcars/issue-42-engineer")

      assert {:ok, {7, "reviewer"}} = ForgeProtocol.parse_feature_branch("lcars/issue-7-reviewer")
    end

    test "parse_feature_branch :error on a non-fleet branch" do
      assert :error = ForgeProtocol.parse_feature_branch("refs/pull/55/head")
      assert :error = ForgeProtocol.parse_feature_branch("main")
      assert :error = ForgeProtocol.parse_feature_branch("feature/manual")
      assert :error = ForgeProtocol.parse_feature_branch(nil)
    end

    test "feature_branch/2 builds the format AND parse∘build == identity" do
      assert "lcars/issue-42-engineer" = ForgeProtocol.feature_branch(42, "engineer")

      for {n, role} <- [{1, "engineer"}, {12, "reviewer"}, {999, "qualifier"}] do
        assert {:ok, {^n, ^role}} =
                 ForgeProtocol.parse_feature_branch(ForgeProtocol.feature_branch(n, role))
      end
    end
  end

  describe "step_run_marker/2 + step_run_marker?/1 (build+parse co-located)" do
    test "step_run_marker? recognizes a marker produced by step_run_marker" do
      assert ForgeProtocol.step_run_marker?(ForgeProtocol.step_run_marker("engineer", "deadbeef"))
    end

    test "step_run_marker? false on a body without marker / non-binary" do
      refute ForgeProtocol.step_run_marker?("just a comment")
      refute ForgeProtocol.step_run_marker?(nil)
    end
  end

  describe "result_block/1 + parse_result_block/1 (round-trip)" do
    test "extracts the map from the ```result block (round-trip with the StepRunCompleter N-04 format)" do
      # Synthetic body in the retained result format; no production serialization is exercised.
      body =
        "Livrable de architect.\n\n```result\n" <>
          ~s({"severity_max":"ok","findings":0}) <> "\n```\n\n[step_run:architect:abc]"

      assert {:ok, %{"severity_max" => "ok", "findings" => 0}} =
               ForgeProtocol.parse_result_block(body)
    end

    test "no result block → nil; invalid JSON → nil; nil → nil" do
      assert nil == ForgeProtocol.parse_result_block("just a comment\n[step_run:x:y]")
      assert nil == ForgeProtocol.parse_result_block("```result\nnot json\n```")
      assert nil == ForgeProtocol.parse_result_block(nil)
    end

    test "result_block/1 round-trip with parse_result_block/1" do
      outputs = %{"severity_max" => "ok", "findings" => 3}
      body = "Livrable.\n" <> ForgeProtocol.result_block(outputs)

      assert {:ok, ^outputs} = ForgeProtocol.parse_result_block(body)
    end

    test "result_block/1: empty map → \"\" (no block, so nothing to parse)" do
      assert "" == ForgeProtocol.result_block(%{})
      assert "" == ForgeProtocol.result_block(nil)
      assert nil == ForgeProtocol.parse_result_block("Livrable sans result.")
    end

    test "result_block/1: payload > 8 KB → note, no truncated JSON" do
      big = %{"blob" => String.duplicate("x", 9000)}
      block = ForgeProtocol.result_block(big)

      refute block =~ "```result"
      # "trop volumineux" pins the FR user-facing note rendered in the forge comment.
      assert block =~ "trop volumineux"
      # the note is not a valid result block → parse returns nil (never truncated JSON).
      assert nil == ForgeProtocol.parse_result_block(block)
    end
  end

  describe "system_authored?/2 (trust primitive)" do
    test "true iff the author's login == bot" do
      assert ForgeProtocol.system_authored?(%{"user" => %{"login" => "lcars-bot"}}, "lcars-bot")
      refute ForgeProtocol.system_authored?(%{"user" => %{"login" => "attacker"}}, "lcars-bot")
    end

    test "false on missing structure / empty bot / non-map" do
      refute ForgeProtocol.system_authored?(%{"body" => "no user"}, "lcars-bot")
      refute ForgeProtocol.system_authored?(%{"user" => %{"login" => "lcars-bot"}}, "")
      refute ForgeProtocol.system_authored?("not a comment", "lcars-bot")
    end
  end

  describe "fleet_prs_by_issue/1 — the single issue↔PR selector (C-05)" do
    test "keeps only pulls whose head parses as a fleet feature-branch, as {issue, pull} pairs" do
      pulls = [
        PayloadFixture.pull(number: 10, head_ref: "lcars/issue-42-engineer"),
        PayloadFixture.pull(number: 11, head_ref: "feature/manual-branch"),
        PayloadFixture.pull(number: 12, head_ref: "lcars/issue-7-reviewer"),
        %{"number" => 13, "head" => %{}}
      ]

      result = ForgeProtocol.fleet_prs_by_issue(pulls)

      # Non-fleet (manual branch) and head-less pulls are dropped; the fleet ones carry their issue N.
      assert [{42, %{"number" => 10}}, {7, %{"number" => 12}}] = result
    end

    test "empty list → empty (Poller/StepRunBuild project a set / a head from this)" do
      assert ForgeProtocol.fleet_prs_by_issue([]) == []
    end
  end

  describe "lot_branch/1 + valid_lot_branch?/1 (build+validate co-located)" do
    test "a slug becomes the lot branch, unchanged" do
      assert {:ok, "lcars/lot-morse-ui-v2"} = ForgeProtocol.lot_branch("morse-ui-v2")
    end

    test "a name that is not a slug is REFUSED, never silently renamed" do
      # Preserve the chosen name by rejecting invalid slugs instead of transforming them.
      assert {:error, {:invalid_slug, "Morse UI v2"}} = ForgeProtocol.lot_branch("Morse UI v2")

      assert {:error, {:invalid_slug, "ecran/accueil"}} =
               ForgeProtocol.lot_branch("ecran/accueil")
    end

    test "the validator accepts what the builder produces, and nothing that merely looks like it" do
      {:ok, built} = ForgeProtocol.lot_branch("paquet-3")
      assert ForgeProtocol.valid_lot_branch?(built)

      # Each of these reaches the dispatch as a clone base if it passes.
      refute ForgeProtocol.valid_lot_branch?("refs/heads/lcars/lot-paquet-3")
      refute ForgeProtocol.valid_lot_branch?("lcars/issue-7-engineer")
      refute ForgeProtocol.valid_lot_branch?("lcars/lot-")
      refute ForgeProtocol.valid_lot_branch?("main")
      refute ForgeProtocol.valid_lot_branch?("workshop")
      refute ForgeProtocol.valid_lot_branch?(nil)
    end
  end

  describe "lot_pointer_line/2 + parse_lot_pointer/1 (round-trip through a real ticket body)" do
    @sha "0123456789abcdef0123456789abcdef01234567"

    test "round-trip through a body that also carries a summary" do
      {:ok, ref} = ForgeProtocol.lot_branch("paquet-3")

      body = """
      Reprendre la doc du protocole Morse a partir du paquet joint.

      ---
      #{ForgeProtocol.lot_pointer_line(ref, @sha)}
      """

      assert {:ok, {^ref, @sha}} = ForgeProtocol.parse_lot_pointer(body)
    end

    test "a ticket WITHOUT a lot is the ordinary case, not an error" do
      assert :none = ForgeProtocol.parse_lot_pointer("Just a plain ticket body.")
      assert :none = ForgeProtocol.parse_lot_pointer(nil)
    end

    test "the pointer SHAPE with an out-of-scheme ref is an ERROR, never :none" do
      # A full pointer shape with an invalid ref must not silently discard the lot.
      body = "Lot: refs/heads/evil @ #{@sha}"

      assert {:error, {:invalid_lot_ref, "refs/heads/evil"}} =
               ForgeProtocol.parse_lot_pointer(body)
    end

    test "the two pointers do not read each other in a body that carries BOTH" do
      {:ok, lot_ref} = ForgeProtocol.lot_branch("paquet-3")

      body = """
      Un resume.

      #{Fleet.Layout.brief_pointer_line("briefs/issue-7-scribe.md", @sha, "o/r")}
      #{ForgeProtocol.lot_pointer_line(lot_ref, @sha)}
      """

      # A parser matching the other line would make the dispatch clone `briefs/x.md` as a branch.
      assert {:ok, {^lot_ref, @sha}} = ForgeProtocol.parse_lot_pointer(body)

      assert {:ok, {"briefs/issue-7-scribe.md", @sha}} =
               Fleet.Layout.parse_brief_pointer(body)
    end
  end
end
