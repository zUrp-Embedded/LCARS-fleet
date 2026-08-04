defmodule Fleet.Workflow.PinningTest do
  @moduledoc """
  A long emission becomes an immutable object with a name; a short one is left alone.

  The problem is not verbosity. A long verdict pasted into a review is unreadable in the UI,
  unquotable — nothing addresses a version of it — and EDITABLE: a human who amends the comment
  amends the only copy, and nothing records that it changed.

  The half that matters most is the failure: a commit that does not land must NOT produce a
  pointer. A long comment is cosmetic; a citation naming nothing is a lie that survives, because the
  reader assumes the doc exists and blames its own search.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Pinning

  @sha String.duplicate("a", 40)

  defp long(n \\ 30), do: Enum.map_join(1..n, "\n", &"ligne #{&1}")

  defp ok_commit do
    fn work_dir, ref, content, opts ->
      send(self(), {:committed, work_dir, ref, content, opts})
      {:ok, @sha}
    end
  end

  defp pin(body, commit_fun) do
    Pinning.render(body,
      work_dir: "/tmp/demo",
      ref: "verdicts/issue-42-qualifier.md",
      kind: "Verdict",
      label: "verdict",
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
      assert opts[:push] == :work_ops
      assert opts[:label] == "verdict"
    end

    test "the surface keeps a truncation, says how much it dropped, and cites the version" do
      posted = pin(long(30), ok_commit())

      assert posted =~ "ligne 1"
      assert posted =~ "ligne 8"
      refute posted =~ "ligne 9"
      assert posted =~ "22 lignes de plus"
      assert posted =~ "Verdict: verdicts/issue-42-qualifier.md @ #{@sha}"
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
      # Longer than a body that just fits under the threshold (10), and deliberately so: what
      # matters is the ceiling, not beating the inline case.
      assert length(thirty) <= 14
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
end
