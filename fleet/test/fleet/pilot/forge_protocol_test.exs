defmodule Fleet.Forge.ProtocolTest do
  use ExUnit.Case, async: true

  # PURE wire-protocol vocabulary (no I/O): build+parse co-located. Each describe proves the
  # invariant `parse ∘ build == identity` (a format change breaks the test here, not in prod).
  alias Fleet.Forge.Protocol, as: ForgeProtocol

  # Executable examples of the @doc (step_run_marker/2 + step_run_marker?/1): the doc stays true
  # or the suite breaks.
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

  # (The route_marker/parse_route_marker tests are removed: the workflow_map position lives in the
  # SCOPED stage/* label of the issue, no longer in a marker-comment — cf.
  # ForgeClient.get_route/post_route.)

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
      # "Livrable …" mirrors the real FR forge comment body posted by the completer.
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
        %{"number" => 10, "head" => %{"ref" => "lcars/issue-42-engineer"}},
        %{"number" => 11, "head" => %{"ref" => "feature/manual-branch"}},
        %{"number" => 12, "head" => %{"ref" => "lcars/issue-7-reviewer"}},
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
end
