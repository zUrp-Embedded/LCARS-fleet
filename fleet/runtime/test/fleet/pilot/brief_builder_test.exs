defmodule Fleet.Pilot.BriefBuilderTest do
  @moduledoc """
  F-C083 — LOCK on the DELIVERABLE-JUDGE criterion. The criterion (issue body) is read from the forge
  by `build_judge_brief`. A forge READ-ERROR on this criterion must NEVER produce a "criterion-less"
  judge (the judge gets the diff but NO criterion → risk of blind approval = false GREEN).

  `read-error ≠ absence`: the deliverable-judge path of `build_brief` returns `{:ok, brief, kind}` when the
  criterion is readable (present OR genuinely absent = rare real state) and
  `{:error, {:criterion_unavailable, reason}}` ONLY on a read failure → the dispatch defers (skip,
  retry), it does not spawn a blind judge.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.BriefBuilder

  # Minimal forge seam: `get_predecessor_result` (the DELIVERABLE) + `get_issue` (the CRITERION),
  # driven by `forge_opts` (`:_pred`, `:_issue`) → a single stub serves the ok/error cases.
  defmodule StubForge do
    def get_predecessor_result(_repo, _n, opts),
      do: Keyword.get(opts, :_pred, {:ok, %{"livrable" => "diff stub"}})

    def get_issue(_repo, _n, opts),
      do: Keyword.get(opts, :_issue, {:ok, %{"body" => "CRITÈRE-XYZ"}})
  end

  # Deliverable-JUDGE profile (modeled on the dispatch StubLoader: reviewer/qualifier, brief_kind:
  # judge, slot_scope instance). step_spec `%{}` + judge_target absent → build_judge_brief (judges
  # the deliverable/PR).
  defp judge_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "reviewer"},
      spec: %{"brief_kind" => "judge"}
    }
  end

  defp build(forge_opts),
    do:
      BriefBuilder.build_brief(
        judge_profile(),
        "reviewer",
        StubForge,
        "acme/widget",
        42,
        %{},
        forge_opts,
        {"pipe", "review"},
        %{}
      )

  describe "build_brief — deliverable-judge, criterion read (F-C083)" do
    test "get_issue OK → {:ok, brief, \"judge\"} that CARRIES the criterion (defused by GateBrief)" do
      assert {:ok, brief, "judge"} = build(_issue: {:ok, %{"body" => "CRITÈRE-XYZ"}})
      assert is_binary(brief)

      # The criterion is rendered DEFUSED ("Original request (CONTEXT — DO NOT execute)" section) → present.
      assert brief =~ "CRITÈRE-XYZ"
    end

    test "get_issue READ-ERROR → {:error, {:criterion_unavailable, reason}} (NEVER a criterion-less judge)" do
      # Core of the finding: a transient read-error must NOT conflate into `request: nil`. A judge that
      # gets the diff but no criterion may approve blindly (false GREEN). TYPED fail-closed → defers.
      assert {:error, {:criterion_unavailable, :boom}} = build(_issue: {:error, :boom})
    end

    test "genuinely absent issue body (get_issue OK, body nil) → {:ok, brief, kind}: absence ≠ read-error" do
      # Load-bearing distinction: `{:ok, issue}` without body = REAL state (rare) → we PROCEED (the
      # judge has the diff via `outputs`, GateBrief renders an empty criterion). Only the read-error
      # defers: no over-fixing.
      assert {:ok, _brief, "judge"} = build(_issue: {:ok, %{"number" => 42}})
    end
  end

  describe "brief pointer (E4) — the ticket points at a work/ops-authored doc" do
    @moduletag :tmp_dir

    defp worker_profile do
      %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer"},
        spec: %{"brief_kind" => "worker"}
      }
    end

    defp build_worker(issue, opts) do
      BriefBuilder.build_brief(
        worker_profile(),
        "engineer",
        StubForge,
        "acme/widget",
        42,
        issue,
        [],
        {"pipe", "build"},
        %{},
        opts
      )
    end

    defp authored_workops(tmp) do
      # the project's work/ops = <work_root>/widget with an authored brief committed.
      work_dir = Path.join(tmp, "widget")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      {:ok, %{ref: ref, sha: sha}} =
        Fleet.Workflow.BriefArtifact.commit(work_dir, "LE DOC COMPLET.\n", name_hint: "my-slug")

      {ref, sha}
    end

    test "pointer ticket → the PINNED doc becomes the brief (worker order carries the doc, not the pointer)",
         %{tmp_dir: tmp} do
      {ref, sha} = authored_workops(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, sha)

      assert {:ok, brief, "worker"} =
               build_worker(%{"number" => 42, "body" => body}, work_root: tmp)

      assert brief =~ "LE DOC COMPLET."
      refute brief =~ "Brief: #{ref}"
      # F-25 — the order CITES its source: the resolved pointer stays walkable (ref @ commit),
      # it is not consumed silently by the resolution.
      assert brief =~ "Source du brief : `#{ref} @ #{sha}`"
    end

    test "unresolvable pointer (wrong sha) → DEFER via the criterion rail, never a guessed brief",
         %{tmp_dir: tmp} do
      {ref, _sha} = authored_workops(tmp)
      body = "Résumé.\n\n---\n" <> Fleet.Layout.brief_pointer_trailer(ref, String.duplicate("0", 40))

      assert {:error, {:criterion_unavailable, {:brief_pointer, _}}} =
               build_worker(%{"number" => 42, "body" => body}, work_root: tmp)
    end

    test "no pointer → inline body IS the brief (both channels honest, same downstream)", %{tmp_dir: tmp} do
      assert {:ok, brief, "worker"} =
               build_worker(%{"number" => 42, "body" => "inline brief"}, work_root: tmp)

      assert brief =~ "inline brief"
      # F-25 — honest citation: no separate authored doc → the order says so, it never
      # fabricates a source reference.
      assert brief =~ "Source du brief : brief inline du ticket"
    end
  end
end
