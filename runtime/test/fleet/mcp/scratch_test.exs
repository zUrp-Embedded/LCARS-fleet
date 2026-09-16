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

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)
  defp g(dir, args), do: git(["-C", dir] ++ args)

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
    test "the stamp is a #### heading on LINE 2, carrying the year AND the role", %{
      dir: dir,
      path: path
    } do
      # Include the year so a long-lived scratchpad distinguishes successive Januaries, and the
      # role because the commit cannot carry it: it is signed by the system on both sides.
      {:ok, _} = park("une note", dir)
      [_blank, second | _] = String.split(File.read!(path), "\n")

      assert second =~ ~r/^#### \d{4}-\d{2}-\d{2} - \d{2}:\d{2} — architect$/
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

  # ⚠ CE FICHIER NE POSAIT AUCUN DEPOT GIT : chaque cas loggait « not a git repository », donc la
  # PUBLICATION de la note n'etait jouee par rien — et la portee du commit, qui est le defaut mesure
  # sur banc (deux documents de cadrage partis sous « chore(scratch): note d'atelier »), n'avait
  # aucun temoin. Ces cas-la posent un vrai depot et une vraie origine.
  describe "la publication de la note" do
    setup %{dir: dir, tmp: tmp} do
      # DANS le tmp du cas : une origine partagee entre deux cas se fait rejeter le second push,
      # et le temoin mesurerait alors sa propre mise en scene.
      bare = Path.join(tmp, "origin.git")
      {_, 0} = git(["init", "-q", "--bare", "-b", "workshop", bare])
      {_, 0} = git(["init", "-q", "-b", "workshop", dir])
      {_, 0} = g(dir, ["config", "user.email", "lcars@machine"])
      {_, 0} = g(dir, ["config", "user.name", "lcars"])
      {_, 0} = g(dir, ["remote", "add", "origin", bare])
      File.write!(Path.join(dir, "README.md"), "atelier\n")
      {_, 0} = g(dir, ["add", "."])
      {_, 0} = g(dir, ["commit", "-q", "-m", "base"])
      {_, 0} = g(dir, ["push", "-q", "origin", "HEAD:workshop"])
      {:ok, bare: bare}
    end

    test "la note part sur la forge, sous l'identite du systeme et avec le role en trailer", %{
      dir: dir,
      bare: bare
    } do
      {:ok, _} = park("une note", dir)

      {out, 0} = g(dir, ["log", "-1", "--format=%s%n%ae%n%ce"])
      [sujet, ae, ce] = String.split(String.trim(out), "\n")
      assert sujet == "chore(scratch): note d'atelier (architect)"
      assert ae == Fleet.Credentials.ForgeIdentity.system_email()
      assert ce == ae

      {out, 0} = g(dir, ["log", "-1", "--format=%(trailers:key=Co-authored-by,valueonly)"])
      assert String.trim(out) =~ "LCARS-architect"

      {out, 0} = git(["-C", bare, "log", "-1", "--format=%s", "workshop"])
      assert String.trim(out) == "chore(scratch): note d'atelier (architect)"
    end

    # LE DEFAUT MESURE SUR BANC : un document commite (ou seulement indexe) a cote partait sous le
    # message de la note, sans que personne ne l'ait demande. La note ne commite QUE sa note.
    test "un fichier indexe a cote NE PART PAS avec la note", %{dir: dir} do
      File.write!(Path.join(dir, "spec.md"), "# une spec en cours\n")
      {_, 0} = g(dir, ["add", "spec.md"])

      {:ok, _} = park("une note", dir)

      {out, 0} = g(dir, ["show", "--name-only", "--format=", "HEAD"])
      fichiers = out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      assert fichiers == ["scratchpad.md"]
      # la spec reste indexee, intacte : la note ne l'a ni publiee ni desindexee
      {out, 0} = g(dir, ["diff", "--cached", "--name-only"])
      assert String.trim(out) == "spec.md"
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
