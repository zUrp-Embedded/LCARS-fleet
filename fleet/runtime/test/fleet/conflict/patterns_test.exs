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
    test "same code, different indentation -> prefer ours" do
      content = diff3("a", "  a", "    a")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :whitespace_only}] = r.hunks
      assert r.merged == "a"
    end

    test "whitespace inside a string is data -> not whitespace_only" do
      # ours and theirs normalize equal on layout but the quoted content differs
      content = diff3(~s|x = "a  b"|, ~s|x = "a b"|, ~s|x = "a b"|)
      {:ok, r} = Conflict.resolve(content)
      refute match?([%{type: :whitespace_only}], r.hunks)
    end
  end

  describe "reorder_only" do
    test "same lines, different order (diff2) -> accept theirs order" do
      content = diff2("import a\nimport b", "import b\nimport a")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :reorder_only}] = r.hunks
      assert r.merged == "import b\nimport a"
    end
  end

  describe "insertion_at_boundary" do
    test "both sides insert at the same boundary -> union" do
      content = diff3("a\nX", "a", "a\nY")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :insertion_at_boundary}] = r.hunks
      assert r.merged == "a\nX\nY"
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

    test "at :medium floor, resolves to the highest semver" do
      content = diff3("version = 1.2.0", "version = 1.0.0", "version = 1.1.0")
      {:ok, r} = Conflict.resolve(content, min_confidence: :medium)
      assert r.merged == "version = 1.2.0"
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
