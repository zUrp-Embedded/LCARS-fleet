defmodule Fleet.API.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Fleet.API.BuildInfo

  describe "current/0" do
    # SHAPE seule (pas un SHA littéral — non-hermétique). Quel que soit le
    # contexte (release / working_tree / unknown), le contrat de forme tient.
    test "rend une SHAPE stable (sha binaire non-vide, source dans l'enum, dirty bool, ref binaire|nil)" do
      assert %{sha: sha, dirty: dirty, ref: ref, source: source} = BuildInfo.current()
      assert is_binary(sha) and sha != ""
      assert source in [:release, :working_tree, :unknown]
      assert is_boolean(dirty)
      assert is_nil(ref) or is_binary(ref)
    end
  end

  describe "read_release_file/1 (seam parse :release)" do
    @tag :tmp_dir
    test "parse un fichier build_info contrôlé → source: :release", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "build_info.txt")
      File.write!(path, "sha=deadbee\ndirty=true\nref=feature/x\n")

      assert {:ok, %{sha: "deadbee", dirty: true, ref: "feature/x", source: :release}} =
               BuildInfo.read_release_file(path)
    end

    @tag :tmp_dir
    test "ref vide → nil ; dirty != 'true' → false", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "build_info.txt")
      File.write!(path, "sha=abc1234\ndirty=false\nref=\n")

      assert {:ok, %{sha: "abc1234", dirty: false, ref: nil, source: :release}} =
               BuildInfo.read_release_file(path)
    end

    test "fichier absent → :error (current/0 bascule alors sur working_tree)" do
      assert :error = BuildInfo.read_release_file("/nonexistent/lcars/build_info.txt")
    end
  end
end
