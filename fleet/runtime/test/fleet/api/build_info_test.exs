defmodule Fleet.API.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Fleet.API.BuildInfo

  describe "current/0" do
    # SHAPE only (not a literal SHA — non-hermetic). Whatever the context
    # (release / working_tree / unknown), the shape contract holds.
    test "returns a stable SHAPE (non-empty binary sha, source in the enum, dirty bool, binary|nil ref)" do
      assert %{sha: sha, dirty: dirty, ref: ref, source: source} = BuildInfo.current()
      assert is_binary(sha) and sha != ""
      assert source in [:release, :working_tree, :unknown]
      assert is_boolean(dirty)
      assert is_nil(ref) or is_binary(ref)
    end
  end

  describe "read_release_file/1 (:release parse seam)" do
    @tag :tmp_dir
    test "parses a controlled build_info file → source: :release", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "build_info.txt")
      File.write!(path, "sha=deadbee\ndirty=true\nref=feature/x\n")

      assert {:ok, %{sha: "deadbee", dirty: true, ref: "feature/x", source: :release}} =
               BuildInfo.read_release_file(path)
    end

    @tag :tmp_dir
    test "empty ref → nil ; dirty != 'true' → false", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "build_info.txt")
      File.write!(path, "sha=abc1234\ndirty=false\nref=\n")

      assert {:ok, %{sha: "abc1234", dirty: false, ref: nil, source: :release}} =
               BuildInfo.read_release_file(path)
    end

    test "missing file → :error (current/0 then falls back to working_tree)" do
      assert :error = BuildInfo.read_release_file("/nonexistent/lcars/build_info.txt")
    end
  end
end
