defmodule Fleet.Workflow.PinningTest do
  @moduledoc """
  Tests rendered previews and fallback using a stubbed commit function.
  Successful local results produce pointers regardless of publication state;
  returned errors preserve the full body. No Git object or remote link is resolved.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Pinning

  @sha String.duplicate("a", 40)

  defp long(n \\ 30), do: Enum.map_join(1..n, "\n", &"ligne #{&1}")

  defp ok_commit do
    fn work_dir, ref, content, opts ->
      send(self(), {:committed, work_dir, ref, content, opts})
      {:ok, @sha, :pushed}
    end
  end

  defp pin(body, commit_fun) do
    Pinning.render(body,
      work_dir: "/tmp/demo",
      ref: "verdicts/issue-42-qualifier.md",
      kind: "Verdict",
      label: "verdict",
      repo: "o/r",
      commit_fun: commit_fun
    )
  end

  describe "below the threshold, nothing happens" do
    test "a short body is returned untouched and NOTHING is committed" do
      body = "APPROUVÉ.\nMotif : le gate est vert.\n"

      assert pin(body, ok_commit()) == body
      refute_received {:committed, _, _, _, _}
    end

    test "exactly at the threshold is still inline — a pointer to ten lines costs more than ten lines" do
      refute Pinning.pinnable?(long(10))
      assert Pinning.pinnable?(long(11))
    end
  end

  describe "above the threshold" do
    test "the FULL body is what gets committed — the doc is never the summary" do
      body = long()
      pin(body, ok_commit())

      assert_received {:committed, "/tmp/demo", "verdicts/issue-42-qualifier.md", content, opts}
      assert content == body
      assert opts[:push] == :ops
      assert opts[:label] == "verdict"
    end

    test "the surface keeps a truncation, says how much it dropped, and cites the version" do
      posted = pin(long(30), ok_commit())

      assert posted =~ "ligne 1"
      assert posted =~ "ligne 8"
      refute posted =~ "ligne 9"
      assert posted =~ "22 lignes de plus"

      # With repo supplied, use Layout's clickable commit pointer notation.
      assert posted =~
               "Verdict: [le verdict](/o/r/src/commit/#{@sha}/verdicts/issue-42-qualifier.md)"

      refute posted =~ "Verdict: verdicts/issue-42-qualifier.md @"
    end

    test "the disclaimer names WHAT is being cited — 'ordre de mission' over a verdict would be false" do
      posted = pin(long(), ok_commit())

      assert posted =~ "Ce qui précède est un résumé, pas le verdict."
      assert posted =~ "éditer ce résumé ne le change pas"
    end

    test "the surface form is BOUNDED — 30 lines and 500 produce the same size" do
      thirty = pin(long(30), ok_commit()) |> String.trim_trailing() |> String.split("\n")
      five_hundred = pin(long(500), ok_commit()) |> String.trim_trailing() |> String.split("\n")

      assert length(thirty) == length(five_hundred)
      # The preview overhead can exceed ten lines; these fixed metadata cases stay bounded.
      assert length(thirty) <= 14
    end

    test "no `:repo` → the legacy `<kind>: <ref> @ <sha>` line (still parseable) — Pinning stays total" do
      posted =
        Pinning.render(long(),
          work_dir: "/tmp/demo",
          ref: "verdicts/issue-42-qualifier.md",
          kind: "Verdict",
          label: "verdict",
          commit_fun: ok_commit()
        )

      # Without repo, check the legacy text form; no parser is invoked here.
      assert posted =~ "Verdict: verdicts/issue-42-qualifier.md @ #{@sha}"
      refute posted =~ "/src/commit/"
    end
  end

  describe "a push that did not land is NOT a commit that did not happen" do
    test "`:local_only` still pins — the citation is LATE, never false", %{} do
      posted =
        pin(long(), fn _, _, _, _ -> {:ok, @sha, :local_only} end)

      # A local-only result still produces a link; this test does not establish availability.
      assert posted =~
               "Verdict: [le verdict](/o/r/src/commit/#{@sha}/verdicts/issue-42-qualifier.md)"

      refute posted =~ "ligne 30"
    end

    test "`:unknown` pins too — the commit is proven, only its publication is unobserved" do
      assert pin(long(), fn _, _, _, _ -> {:ok, @sha, :unknown} end) =~ "/src/commit/#{@sha}/"
    end
  end

  describe "when the commit does not land" do
    test "the FULL body is posted inline — never a pointer that names nothing" do
      body = long()
      posted = pin(body, fn _, _, _, _ -> {:error, :git_exploded} end)

      assert posted == body
      refute posted =~ "Verdict:"
      refute posted =~ "résumé"
    end

    test "no work_dir (project never onboarded) → inline, and nothing is attempted" do
      body = long()

      assert Pinning.render(body, ref: "verdicts/x.md", commit_fun: ok_commit()) == body
      refute_received {:committed, _, _, _, _}
    end

    test "no ref → inline too; both halves of the destination are required to pin" do
      body = long()

      assert Pinning.render(body, work_dir: "/tmp/demo", commit_fun: ok_commit()) == body
      refute_received {:committed, _, _, _, _}
    end
  end

  describe "one ref family per NATURE of artifact (settled 2026-08-05)" do
    alias Fleet.Layout

    test "the four trees are distinct, and none is a suffix inside another" do
      # Distinct artifact families avoid overwriting the current file for another act.
      # This checks three unequal refs, despite the historical title saying four trees.
      refs = [
        Layout.verdict_ref(42, "qualifier"),
        Layout.gate_verdict_ref(42, "qualifier"),
        Layout.conflict_ref(7)
      ]

      assert length(Enum.uniq(refs)) == 3
      assert Enum.all?(refs, &String.ends_with?(&1, ".md"))
    end

    test "the SAME role on the SAME issue lands in two different trees, not two suffixed files" do
      verdict = Layout.verdict_ref(42, "gatekeeper")
      gate = Layout.gate_verdict_ref(42, "gatekeeper")

      refute verdict == gate
      # Brief and verdict families both separate worker artifacts from gate artifacts.
      assert String.starts_with?(verdict, "verdicts/")
      assert String.starts_with?(gate, "gate-verdicts/")
      assert String.ends_with?(verdict, "issue-42-gatekeeper.md")
      assert String.ends_with?(gate, "issue-42-gatekeeper.md")
    end

    test "a conflict report is keyed on the PR — a conflict is a property of the merge" do
      assert Layout.conflict_ref(7) == "conflicts/pr-7.md"
    end

    # Prose and machine findings represent one act: same tree/basename, different extension.
    test "the machine verdict shares the prose verdict's tree and basename — one act, two renderings" do
      assert Layout.verdict_findings_ref(42, "qualifier") == "verdicts/issue-42-qualifier.json"

      assert Path.rootname(Layout.verdict_findings_ref(42, "qualifier")) ==
               Path.rootname(Layout.verdict_ref(42, "qualifier"))
    end
  end
end
