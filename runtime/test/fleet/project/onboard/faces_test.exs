defmodule Fleet.Project.Onboard.FacesTest do
  @moduledoc """
  The three faces of a project are three ORPHAN branches of ONE repository, each cloned into its
  own directory. These witnesses hold the line that separates them at the OBJECT level: a face
  fetches its own branch and nothing else, so a file dropped on workshop never lands in the clone
  the pods take. Measured against real repositories, never against a recorded argv.
  """
  use ExUnit.Case, async: true

  alias Fleet.Layout
  alias Fleet.Project.Onboard.Faces

  @moduletag :tmp_dir

  defmodule PresentBranch do
    @moduledoc false
    def branch_exists?(_full_name, _branch, _fc), do: {:ok, true}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    String.trim(out)
  end

  defp git_code(dir, args) do
    {_out, code} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)
    code
  end

  defp fetch_refspec(dir), do: git!(dir, ["config", "--get-all", "remote.origin.fetch"])

  defp remote_branches(dir) do
    dir
    |> git!(["for-each-ref", "--format=%(refname)", "refs/remotes/origin"])
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.ends_with?(&1, "/HEAD"))
    |> Enum.map(&String.replace_prefix(&1, "refs/remotes/", ""))
  end

  # ⚠ `file://` ET NON LE CHEMIN NU : un clone depuis un chemin local passe par `--local`, qui
  # DURCIT le repertoire d'objets entier et ignore `--single-branch`. La forge est jointe par un
  # transport ; un temoin qui clone un chemin nu mesurerait autre chose que le code en service.
  defp forge_url(src), do: "file://" <> src

  # Un depot de projet tel que la forge le porte : main, puis ops et workshop en ORPHELINES. Le
  # fichier de workshop est gros assez pour qu'un blob partage se voie, et distinct sur le disque.
  defp forge_repo!(root) do
    src = Path.join(root, "forge-src")
    File.mkdir_p!(src)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
    git!(src, ["config", "user.email", "t@lcars.local"])
    git!(src, ["config", "user.name", "test"])
    File.write!(Path.join(src, "code.txt"), "the code face")
    git!(src, ["add", "-A"])
    git!(src, ["commit", "-q", "-m", "main"])

    for {branch, file, body} <- [
          {"ops", "brief.md", "the ops face"},
          {"workshop", "firmware.bin", String.duplicate("what the human drops off\n", 4096)}
        ] do
      git!(src, ["checkout", "-q", "--orphan", branch])
      wipe_worktree(src)
      File.write!(Path.join(src, file), body)
      git!(src, ["add", "-A"])
      git!(src, ["commit", "-q", "-m", branch])
    end

    git!(src, ["checkout", "-q", "-f", "main"])
    src
  end

  defp wipe_worktree(dir) do
    dir
    |> File.ls!()
    |> Enum.reject(&(&1 == ".git"))
    |> Enum.each(&File.rm_rf!(Path.join(dir, &1)))
  end

  describe "the faces do not cross" do
    test "the three faces are ORPHAN branches: no merge-base, so no content travels", %{
      tmp_dir: tmp
    } do
      src = forge_repo!(tmp)

      assert git_code(src, ["merge-base", "main", "ops"]) != 0
      assert git_code(src, ["merge-base", "main", "workshop"]) != 0
      assert git_code(src, ["merge-base", "ops", "workshop"]) != 0
    end

    test "clone_main takes ONE face: a BARE fetch does not drag the neighbours' objects", %{
      tmp_dir: tmp
    } do
      src = forge_repo!(tmp)
      blob = git!(src, ["rev-parse", "workshop:firmware.bin"])
      code_face = Path.join([tmp, "projects", "garage"])

      assert :ok = Faces.clone_main(forge_url(src), code_face)
      assert fetch_refspec(code_face) == "+refs/heads/main:refs/remotes/origin/main"

      # Le fetch NU est celui que le runtime fait quand il ne nomme rien : c'est LUI qui rapatriait
      # tout. Un refspec resserre le borne a la face, sans qu'aucun appelant ait a le savoir.
      git!(code_face, ["fetch", "origin"])

      assert remote_branches(code_face) == ["origin/main"]
      assert git_code(code_face, ["cat-file", "-e", blob]) != 0
    end

    test "ensure_face clones a writer face on ITS branch only", %{tmp_dir: tmp} do
      src = forge_repo!(tmp)
      blob = git!(src, ["rev-parse", "main:code.txt"])
      dir = Path.join([tmp, "doc", "garage"])
      face = %{dir: dir, branch: "workshop", template: "workshop"}

      assert {:ok, :cloned} =
               Faces.ensure_face("fleet/garage", forge_url(src), face, "garage",
                 forge_repo: PresentBranch
               )

      assert fetch_refspec(dir) == "+refs/heads/workshop:refs/remotes/origin/workshop"

      git!(dir, ["fetch", "origin"])

      assert remote_branches(dir) == ["origin/workshop"]
      assert git_code(dir, ["cat-file", "-e", blob]) != 0
    end

    test "init_face tracks ONE branch: a face PUBLISHED, never cloned, has the same guard", %{
      tmp_dir: tmp
    } do
      dir = Path.join([tmp, "work", "garage"])

      assert :ok = Faces.init_face(dir, "http://forge.example/fleet/garage.git", "ops")
      assert fetch_refspec(dir) == "+refs/heads/ops:refs/remotes/origin/ops"
    end
  end

  # Sans mode explicite, la face nait sous l'umask du BEAM : l'atelier cesse d'etre ecrivable par le
  # groupe et un depot humain s'y refuse, sans message. Le mode se pose donc la ou le repertoire
  # nait, pas dans chacun des trois appelants — dont deux l'oubliaient.
  describe "le MODE d'une face se pose ou elle nait" do
    defp mode_of(dir), do: Bitwise.band(File.stat!(dir).mode, 0o7777)

    test "init_face pose le mode DECLARE de la face d'ecriture, atelier et ops", %{tmp_dir: tmp} do
      url = "http://forge.example/fleet/garage.git"
      atelier = Path.join([tmp, "doc", "garage"])
      ops = Path.join([tmp, "work", "garage"])

      assert :ok = Faces.init_face(atelier, url, Layout.workshop_branch())
      assert :ok = Faces.init_face(ops, url, Layout.ops_branch())

      # Les deux, jamais un seul : une valeur attendue peut coincider avec l'umask du processus.
      assert mode_of(atelier) == Layout.writer_face_mode("workshop")
      assert mode_of(ops) == Layout.writer_face_mode("ops")
      assert Layout.writer_face_mode("workshop") != Layout.writer_face_mode("ops")
    end

    test "aucune regle pour la face de CODE : l'umask decide, on n'invente pas un mode", %{
      tmp_dir: tmp
    } do
      code = Path.join([tmp, "projects", "garage"])

      assert Layout.writer_face_mode("code") == nil
      assert :ok = Faces.init_face(code, "http://forge.example/fleet/garage.git", "main")
      assert File.dir?(code)
    end
  end

  describe "set_origin" do
    test "named branch NARROWS the refspec, whether origin was there or not", %{tmp_dir: tmp} do
      src = forge_repo!(tmp)
      url = "http://forge.example/fleet/garage.git"

      # Origin ABSENT : l'arbre que le kit pose n'en a aucun.
      fresh = Path.join([tmp, "projects", "fresh"])
      File.mkdir_p!(fresh)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", fresh], stderr_to_stdout: true)

      assert :ok = Faces.set_origin(fresh, url, "main")
      assert git!(fresh, ["config", "--get", "remote.origin.url"]) == url
      assert fetch_refspec(fresh) == "+refs/heads/main:refs/remotes/origin/main"

      # Origin PRESENT et large : le cas d'une face clonee avant ce garde-fou.
      wide = Path.join([tmp, "projects", "wide"])
      {_, 0} = System.cmd("git", ["clone", "-q", src, wide], stderr_to_stdout: true)
      assert fetch_refspec(wide) == "+refs/heads/*:refs/remotes/origin/*"

      assert :ok = Faces.set_origin(wide, url, "main")
      assert git!(wide, ["config", "--get", "remote.origin.url"]) == url
      assert fetch_refspec(wide) == "+refs/heads/main:refs/remotes/origin/main"
    end

    test "WITHOUT a branch the refspec is left alone: the import scratch pushes three", %{
      tmp_dir: tmp
    } do
      src = forge_repo!(tmp)
      scratch = Path.join(tmp, "scratch")
      {_, 0} = System.cmd("git", ["clone", "-q", src, scratch], stderr_to_stdout: true)

      assert :ok = Faces.set_origin(scratch, "http://forge.example/fleet/garage.git")
      assert fetch_refspec(scratch) == "+refs/heads/*:refs/remotes/origin/*"
    end
  end
end
