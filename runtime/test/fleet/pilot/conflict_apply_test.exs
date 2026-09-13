defmodule Fleet.Pilot.ConflictApplyTest do
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ConflictApply

  defp sh(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp cfg(dir) do
    sh(dir, ["config", "user.email", "t@example.test"])
    sh(dir, ["config", "user.name", "Test"])
  end

  # Bare remote with main + feature that both change `f.txt` off a common base -> a real conflict.
  # Returns a fresh clone (standing in for the runtime's local clone).
  defp setup_remote(base, feature_line, main_line),
    do: setup_remote(base, "\ta = 1\n", feature_line, main_line)

  defp setup_remote(base, base_content, feature_line, main_line) do
    remote = Path.join(base, "remote.git")
    work = Path.join(base, "work")
    System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    System.cmd("git", ["clone", "-q", remote, work])
    cfg(work)

    File.write!(Path.join(work, "f.txt"), base_content)
    sh(work, ["add", "."])
    sh(work, ["commit", "-qm", "base"])
    sh(work, ["push", "-q", "origin", "main"])

    sh(work, ["checkout", "-qb", "feature"])
    File.write!(Path.join(work, "f.txt"), feature_line)
    sh(work, ["commit", "-qam", "feature"])
    sh(work, ["push", "-q", "origin", "feature"])

    sh(work, ["checkout", "-q", "main"])
    File.write!(Path.join(work, "f.txt"), main_line)
    sh(work, ["commit", "-qam", "main change"])
    sh(work, ["push", "-q", "origin", "main"])

    clone = Path.join(base, "clone")
    System.cmd("git", ["clone", "-q", remote, clone])
    cfg(clone)
    clone
  end

  defp main_is_ancestor_of_feature?(clone) do
    sh(clone, ["fetch", "-q", "origin"])

    {_, code} =
      sh(clone, ["merge-base", "--is-ancestor", "origin/main", "origin/feature"])

    code == 0
  end

  @tag :tmp_dir
  test "auto-resolves a WRITABLE conflict (non_overlapping) and pushes", %{tmp_dir: base} do
    # Adjacent edits conflict in Git context but affect disjoint base regions.
    clone =
      setup_remote(
        base,
        "un\ndeux\ntrois\nquatre\n",
        "un\nDEUX-feature\ntrois\nquatre\n",
        "un\ndeux\nTROIS-main\nquatre\n"
      )

    assert {:ok, :auto_resolved} =
             ConflictApply.apply_in(clone, "feature", base_branch: "origin/main", auth: false)

    # This fixture's pushed feature contains the fetched main commit.
    assert main_is_ancestor_of_feature?(clone)

    sh(clone, ["fetch", "-q", "origin"])
    {blob, 0} = sh(clone, ["show", "origin/feature:f.txt"])
    assert blob =~ "DEUX-feature"
    assert blob =~ "TROIS-main"
  end

  @tag :tmp_dir
  test "a WHITESPACE conflict is NOT auto-pushed — the format assumption stops here", %{
    tmp_dir: base
  } do
    # Whitespace can change Python blocks or YAML ownership; format-blind resolution
    # must not auto-push this fixture.
    clone = setup_remote(base, "  a = 1\n", "    a = 1\n")

    assert {:error, _} =
             ConflictApply.apply_in(clone, "feature", base_branch: "origin/main", auth: false)

    refute main_is_ancestor_of_feature?(clone)
  end

  @tag :tmp_dir
  test "a complex (value) conflict is NOT auto-resolved; the feature branch is untouched",
       %{tmp_dir: base} do
    clone = setup_remote(base, "v=2\n", "v=3\n")

    assert {:error, _} =
             ConflictApply.apply_in(clone, "feature", base_branch: "origin/main", auth: false)

    refute main_is_ancestor_of_feature?(clone)
  end

  @tag :tmp_dir
  test "un marqueur ORPHELIN dans le contenu abandonne le merge — il ne pousse pas un fichier ampute",
       %{tmp_dir: base} do
    # An otherwise writable conflict includes a legitimate orphan marker in file content.
    # Regression: the parser discarded that marker and its suffix before an unsafe push.
    doc = "<<<<<<< exemple tire de la doc git\ncinq\n"

    clone =
      setup_remote(
        base,
        "un\ndeux\ntrois\nquatre\n" <> doc,
        "un\nDEUX-feature\ntrois\nquatre\n" <> doc,
        "un\ndeux\nTROIS-main\nquatre\n" <> doc
      )

    assert {:error, _} =
             ConflictApply.apply_in(clone, "feature", base_branch: "origin/main", auth: false)

    refute main_is_ancestor_of_feature?(clone)

    sh(clone, ["fetch", "-q", "origin"])
    {blob, 0} = sh(clone, ["show", "origin/feature:f.txt"])
    assert blob =~ "exemple tire de la doc git"
    assert blob =~ "cinq"
  end
end
