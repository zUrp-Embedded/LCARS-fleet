defmodule Fleet.Conflict.PatternsTest do
  use ExUnit.Case, async: true

  alias Fleet.Conflict
  alias Fleet.Conflict.{Diff, Patterns.Utils}

  defp diff3(ours, base, theirs) do
    "<<<<<<< ours\n#{ours}\n||||||| base\n#{base}\n=======\n#{theirs}\n>>>>>>> theirs"
  end

  defp diff2(ours, theirs) do
    "<<<<<<< ours\n#{ours}\n=======\n#{theirs}\n>>>>>>> theirs"
  end

  describe "non_overlapping" do
    test "disjoint insertions merge via 3-way LCS" do
      content = diff3("a\nX\nb\nc", "a\nb\nc", "a\nb\nc\nY")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :non_overlapping}] = r.hunks
      assert r.merged == "a\nX\nb\nc\nY"
    end
  end

  describe "whitespace_only" do
    test "same code, different indentation -> CLASSIFIED, never auto-written" do
      # Classification is real and useful (it routes the tier: this is shallow). Writing it is not
      # ours to do: the engine is format-blind, and in Python an indent/dedent changes scope, in
      # YAML it changes which key owns the value. Measured on the deployed build before this gate:
      # `    return a` vs `\treturn a` resolved at :high and rewrote the block.
      content = diff3("a", "  a", "    a")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :whitespace_only, confidence: %{label: :high}}] = r.hunks
      refute r.merged, "a whitespace assumption must never reach the worktree"
      assert r.stats == %{trivial: 1, complex: 0, total: 1, writable: 0}
    end

    test "whitespace inside a string is data -> not whitespace_only" do
      # ours and theirs normalize equal on layout but the quoted content differs
      content = diff3(~s|x = "a  b"|, ~s|x = "a b"|, ~s|x = "a b"|)
      {:ok, r} = Conflict.resolve(content)
      refute match?([%{type: :whitespace_only}], r.hunks)
    end
  end

  describe "reorder_only" do
    test "same lines, different order (diff2) -> CLASSIFIED, never auto-written" do
      # Order carries meaning far too often to guess: `RUN apt update` after `apt install`, CSS
      # last-declaration-wins, and `log()` before `auth()` -- the engine reordered an auth check
      # ahead of its log at :high before this gate.
      content = diff2("a\nb", "b\na")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :reorder_only}] = r.hunks
      refute r.merged, "an order assumption must never reach the worktree"
    end
  end

  describe "insertion_at_boundary" do
    test "both sides insert at the same boundary -> CLASSIFIED, never auto-written" do
      # The union is right when the two insertions are ADDITIVE and wrong when they are
      # ALTERNATIVES -- and nothing in the text says which. Measured before this gate: two sides
      # setting the same key produced `timeout: 30` AND `timeout: 60` (invalid in strict YAML), two
      # sides defining `def run` kept both (dead clause), two sides setting `color:` kept both (ours
      # silently lost to CSS last-wins).
      content = diff3("a\nX", "a", "a\nY")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :insertion_at_boundary}] = r.hunks
      refute r.merged, "keeping both insertions must never reach the worktree unreviewed"
    end
  end

  describe "value_only_change" do
    test "both changed only a version -> classified value_only, medium at 20% ratio" do
      content = diff3("version = 1.2.0", "version = 1.0.0", "version = 1.1.0")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :value_only_change, confidence: %{label: :medium}}] = r.hunks
      # medium -> not auto-resolved at the default :high floor
      assert r.merged == nil
    end

    test "lowering the floor to :medium does NOT unlock it — the type gate is independent" do
      # The confidence floor and the write gate answer different questions. Lowering the floor used
      # to hand the disk to a value pick; it no longer can, because `value_only_change` is not an
      # auto-writable type at ANY floor. The reason is measured, not theoretical: for an unorderable
      # volatile `Assemble` itself records "not orderable -- accept theirs (default)", i.e. a coin
      # flip. A sha `aaaa1111` vs `bbbb2222` resolved to theirs at :high before this gate.
      content = diff3("version = 1.2.0", "version = 1.0.0", "version = 1.1.0")
      {:ok, r} = Conflict.resolve(content, min_confidence: :medium)
      assert [%{type: :value_only_change}] = r.hunks
      refute r.merged
    end

    test "an UNORDERABLE volatile is where the pick is a coin flip (the reason for the gate)" do
      content = diff3(~s|sha = "aaaa1111"|, ~s|sha = "0000abcd"|, ~s|sha = "bbbb2222"|)
      {:ok, r} = Conflict.resolve(content, min_confidence: :low)
      assert [%{type: :value_only_change}] = r.hunks
      refute r.merged, "no ordering exists between two hashes; picking one is not a resolution"
    end
  end

  describe "unit: Diff.merge_non_overlapping" do
    test "overlapping edits -> nil" do
      assert Diff.merge_non_overlapping(["a"], ["b"], ["c"]) == nil
    end

    test "disjoint edits -> merged" do
      assert Diff.merge_non_overlapping(["a", "b"], ["X", "a", "b"], ["a", "b", "Y"]) ==
               ["X", "a", "b", "Y"]
    end
  end

  describe "unit: Utils.pick_newer_side" do
    test "higher semver wins, same side across the block" do
      assert Utils.pick_newer_side(["v = 1.2.0"], ["v = 1.1.0"]) == :ours
      assert Utils.pick_newer_side(["v = 1.1.0"], ["v = 2.0.0"]) == :theirs
    end

    test "disagreeing sides -> nil (fall back to policy)" do
      assert Utils.pick_newer_side(["a = 2.0.0", "b = 1.0.0"], ["a = 1.0.0", "b = 2.0.0"]) == nil
    end

    test "non-orderable values -> nil" do
      assert Utils.pick_newer_side(["h = abcdef1"], ["h = 9876543"]) == nil
    end
  end
end
