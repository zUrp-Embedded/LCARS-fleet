defmodule Fleet.ConflictTest do
  use ExUnit.Case, async: true

  alias Fleet.Conflict

  defp diff3(ours, base, theirs) do
    "<<<<<<< ours\n#{ours}\n||||||| base\n#{base}\n=======\n#{theirs}\n>>>>>>> theirs"
  end

  describe "trivial resolution (diff3)" do
    test "same_change: both sides made the same edit" do
      {:ok, r} = Conflict.resolve(diff3("b", "a", "b"))
      assert r.merged == "b"
      assert [%{type: :same_change}] = r.hunks
      assert r.stats == %{trivial: 1, complex: 0, total: 1, writable: 1}
    end

    test "one_side_change: only theirs changed -> accept theirs" do
      {:ok, r} = Conflict.resolve(diff3("a", "a", "b"))
      assert r.merged == "b"
      assert [%{type: :one_side_change}] = r.hunks
    end

    test "one_side_change: only ours changed -> accept ours" do
      {:ok, r} = Conflict.resolve(diff3("b", "a", "a"))
      assert r.merged == "b"
    end

    test "delete_no_change: ours deleted, theirs untouched -> delete" do
      content = "<<<<<<< ours\n||||||| base\na\n=======\na\n>>>>>>> theirs"
      {:ok, r} = Conflict.resolve(content)
      assert r.merged == ""
      assert [%{type: :delete_no_change}] = r.hunks
    end
  end

  describe "complex -> unresolved, markers restored" do
    test "both sides changed differently" do
      {:ok, r} = Conflict.resolve(diff3("b", "a", "c"))
      assert r.merged == nil
      assert [%{type: :complex}] = r.hunks
      assert r.stats.complex == 1
    end
  end

  describe "surrounding text is preserved" do
    test "leading and trailing text kept around a resolved hunk" do
      content = "top\n" <> diff3("b", "a", "b") <> "\nbottom"
      {:ok, r} = Conflict.resolve(content)
      assert r.merged == "top\nb\nbottom"
    end
  end

  describe "decision trace" do
    test "records the selected type, the base flag, and the passing step" do
      {:ok, r} = Conflict.resolve(diff3("a", "a", "b"))
      [h] = r.hunks
      assert h.trace.selected == :one_side_change
      assert h.trace.has_base
      assert Enum.any?(h.trace.steps, &(&1.type == :one_side_change and &1.passed))
    end
  end

  describe "CRLF separator (ported scar)" do
    test "a CRLF conflict still parses into three sections" do
      content =
        "<<<<<<< ours\r\nb\r\n||||||| base\r\na\r\n=======\r\nb\r\n>>>>>>> theirs\r"

      {:ok, r} = Conflict.resolve(content)

      # ours and theirs are both "b\r" -> same_change (the separator "=======\r" must be recognized)
      assert [%{type: :same_change}] = r.hunks
    end
  end

  describe "diff2 (no base) is conservative" do
    test "a diff2 deletion is only medium confidence -> not auto-resolved at :high" do
      content = "<<<<<<< ours\n=======\na\n>>>>>>> theirs"
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :delete_no_change, confidence: %{label: :medium}}] = r.hunks
      assert r.merged == nil
    end
  end
end
