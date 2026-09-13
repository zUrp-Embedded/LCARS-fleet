defmodule Fleet.MCP.ScratchTest do
  @moduledoc """
  Scratchpad file-format, append behavior and receipt tests in an existing temporary
  directory without a Git repo. The commit attempt fails; publication is not tested.
  Note counts and below-threshold receipts are checked, but the triage threshold
  itself and custom #### headings in note content are not exercised.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools.Delegation.Scratchpad

  setup do
    tmp = Fleet.TestEnv.tmp_path("scratch")
    dir = Path.join(tmp, "demo")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # A missing directory must refuse rather than create an untracked notes directory.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
      {:ok, %{role: "architect", repo: "fleet/demo"}}
    end)

    %{tmp: tmp, dir: dir, path: Path.join(dir, "scratchpad.md")}
  end

  # The workshop root is a layout fact, so the suite points the layout at its own tree rather than
  # writing into `/home/projects.workshop`.
  defp park(note, dir) do
    root = Path.dirname(dir)
    prev = Application.get_env(:lcars_fleet, :mcp_workshop_root)
    Application.put_env(:lcars_fleet, :mcp_workshop_root, root)

    try do
      Scratchpad.scratch(%{pod_id: "pod-arch", role: "architect", repo: "fleet/demo"}, note)
    after
      if prev,
        do: Application.put_env(:lcars_fleet, :mcp_workshop_root, prev),
        else: Application.delete_env(:lcars_fleet, :mcp_workshop_root)
    end
  end

  describe "the block" do
    test "the stamp is a #### heading on LINE 2, carrying the year", %{dir: dir, path: path} do
      # Include the year so a long-lived scratchpad distinguishes successive Januaries.
      {:ok, _} = park("une note", dir)
      [_blank, second | _] = String.split(File.read!(path), "\n")

      assert second =~ ~r/^#### \d{4}-\d{2}-\d{2} - \d{2}:\d{2}$/
    end

    test "the note keeps its line breaks — a block is not a flattened line", %{
      dir: dir,
      path: path
    } do
      {:ok, _} = park("premiere ligne\nseconde ligne", dir)
      content = File.read!(path)

      assert content =~ "premiere ligne\nseconde ligne"
      refute content =~ " / "
    end

    test "the note closes on a rule, and the rule is PRECEDED by a blank line", %{
      dir: dir,
      path: path
    } do
      # A blank before --- prevents Markdown interpreting the final note line as a heading.
      {:ok, _} = park("la note", dir)

      assert File.read!(path) =~ "la note\n\n---\n"
    end

    test "two notes are two blocks, separated by a blank line", %{dir: dir, path: path} do
      {:ok, _} = park("une", dir)
      {:ok, _} = park("deux", dir)
      content = File.read!(path)

      assert length(Regex.scan(~r/^#### /m, content)) == 2
      assert length(Regex.scan(~r/^---$/m, content)) == 2
      # The rule of the first block and the heading of the second never touch.
      assert content =~ ~r/---\n\n#### /
    end
  end

  describe "the door" do
    test "APPEND ONLY: a hand-trimmed file keeps its edits", %{dir: dir, path: path} do
      # Appending must preserve manual triage edits.
      {:ok, _} = park("premiere", dir)
      File.write!(path, "# scratchpad trie a la main\n")
      {:ok, _} = park("seconde", dir)

      content = File.read!(path)
      assert content =~ "# scratchpad trie a la main"
      assert content =~ "seconde"
      refute content =~ "premiere"
    end

    test "an empty note is refused — a stamped block with nothing in it is noise", %{dir: dir} do
      assert {:error, :note_empty} = park("   \n  ", dir)
    end

    test "NO workshop face: refused by name, never created", %{tmp: tmp} do
      # Do not create a standalone directory that lacks the workshop publication context.
      root = Path.join(tmp, "nowhere")
      absent = Path.join(root, "demo")
      prev = Application.get_env(:lcars_fleet, :mcp_workshop_root)
      Application.put_env(:lcars_fleet, :mcp_workshop_root, root)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:lcars_fleet, :mcp_workshop_root, prev),
          else: Application.delete_env(:lcars_fleet, :mcp_workshop_root)
      end)

      assert {:error, {:no_workshop_face, _}} =
               Scratchpad.scratch(%{pod_id: "p", role: "architect", repo: "fleet/demo"}, "x")

      refute File.exists?(absent)
    end
  end

  describe "the nudge rides on the receipt" do
    test "the receipt counts NOTES, not lines — the block format broke that proxy", %{dir: dir} do
      # Multiline notes need heading counts, not physical-line counts.
      {:ok, r1} = park("une", dir)
      assert r1["notes"] == 1

      {:ok, r2} = park("deux\navec un retour", dir)
      assert r2["notes"] == 2
    end

    test "under the threshold the receipt stays a receipt", %{dir: dir} do
      {:ok, r} = park("une", dir)
      refute Map.has_key?(r, "next")
    end
  end
end
