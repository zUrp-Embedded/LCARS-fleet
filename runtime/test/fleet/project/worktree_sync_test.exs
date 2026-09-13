defmodule Fleet.Project.WorktreeSyncTest do
  @moduledoc """
  Exercises alignment and issue-ref fetching with local bare origins and real Git.
  Isolated server names allow concurrent tests. This does not test network credentials,
  linked worktrees, external concurrent writers or every rebase/autostash failure.
  """
  use ExUnit.Case, async: true

  alias Fleet.Project.WorktreeSync

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # bare origin + a seed clone that lands the 1st commit on main (the starting "project").
    origin = Path.join(tmp, "origin.git")
    seed = Path.join(tmp, "seed")
    git!(["init", "--bare", "-b", "main", origin])
    git!(["clone", origin, seed])
    git_in!(seed, ["config", "user.email", "t@lcars"])
    git_in!(seed, ["config", "user.name", "t"])
    commit_push!(seed, "README.md", "v0\n", "init")

    # the local clone = the `/home/projects/<name>` showcase, frozen at start (as at onboarding).
    root = Path.join(tmp, "projects")
    File.mkdir_p!(root)
    proj = Path.join(root, "myproj")
    git!(["clone", origin, proj])

    # Workshop uses a separate branch and clone so local writer commits can be exercised.
    workshop_root = Path.join(tmp, "projects.doc")
    File.mkdir_p!(workshop_root)
    git_in!(seed, ["checkout", "-q", "--orphan", "workshop"])
    git_in!(seed, ["rm", "-rq", "--cached", "."])
    File.write!(Path.join(seed, "backlog.md"), "v0\n")
    git_in!(seed, ["add", "-A"])
    git_in!(seed, ["commit", "-qm", "init doc"])
    git_in!(seed, ["push", "-q", "origin", "workshop"])
    git_in!(seed, ["checkout", "-q", "main"])
    doc = Path.join(workshop_root, "myproj")
    git!(["clone", "-q", "--branch", "workshop", origin, doc])
    git_in!(doc, ["config", "user.email", "t@lcars"])
    git_in!(doc, ["config", "user.name", "t"])

    # unique name → async tests without collision on the GenServer's global name.
    name = :"wt_#{System.unique_integer([:positive])}"

    start_supervised!({WorktreeSync, name: name, code_root: root, workshop_root: workshop_root})

    %{seed: seed, proj: proj, doc: doc, origin: origin, sync: name}
  end

  test "aligns the local clone on origin/main after an advancement (the deliverable lands on disk)",
       %{seed: seed, proj: proj, sync: sync} do
    # origin advances (the "merge"); the local clone has NOTHING yet (the bug: it stays frozen).
    commit_push!(seed, "hello.sh", "echo hi\n", "feat: hello")
    refute File.exists?(Path.join(proj, "hello.sh"))

    assert :ok = WorktreeSync.sync_now(sync, "fleet/myproj", "main")

    # AFTER: the disk reflects origin/main — same SHA, delivered file present.
    assert File.exists?(Path.join(proj, "hello.sh"))
    assert head(proj) == head(seed)
  end

  # JG-119: the human's code directory can contain uncommitted work despite its mirror role.
  test "JG-119: un arbre SALE n'est pas aligne — le travail non commite survit", %{
    seed: seed,
    proj: proj,
    sync: sync
  } do
    commit_push!(seed, "hello.sh", "echo hi\n", "feat: hello")

    # Du travail humain non commite dans la vitrine : un fichier suivi, modifie.
    precieux = Path.join(proj, "README.md")
    File.write!(precieux, "TRAVAIL HUMAIN NON COMMITE\n")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:worktree_dirty, _}} =
                 WorktreeSync.sync_now(sync, "fleet/myproj", "main")
      end)

    assert File.read!(precieux) == "TRAVAIL HUMAIN NON COMMITE\n",
           "le `reset --hard` a detruit du travail qui n'existe nulle part ailleurs"

    refute File.exists?(Path.join(proj, "hello.sh")),
           "l'alignement a eu lieu quand meme — le refus n'en est pas un"

    assert log =~ "UNCOMMITTED changes",
           "le refus est muet : personne ne saura pourquoi la vitrine est perimee"

    assert log =~ "README.md", "la trace ne dit pas CE QUI bloque"
  end

  test "TEMOIN JG-119 — l'arbre redevenu propre s'aligne au tick suivant", %{
    seed: seed,
    proj: proj,
    sync: sync
  } do
    # Positive control: refusing every alignment must not pass.
    commit_push!(seed, "hello.sh", "echo hi\n", "feat: hello")
    File.write!(Path.join(proj, "README.md"), "sale\n")

    assert {:error, {:worktree_dirty, _}} = WorktreeSync.sync_now(sync, "fleet/myproj", "main")

    # L'humain range (ici : il jette).
    git_in!(proj, ["checkout", "--", "README.md"])

    assert :ok = WorktreeSync.sync_now(sync, "fleet/myproj", "main")
    assert File.exists?(Path.join(proj, "hello.sh"))
    assert head(proj) == head(seed)
  end

  test "local clone absent → :ok (nothing to align: the clone is a MIRROR, the truth = main merged on the forge; skip logged debug)",
       %{sync: sync} do
    assert :ok = WorktreeSync.sync_now(sync, "fleet/jamais-clone", "main")
  end

  test "concurrent syncs on the same worktree: serialized, all :ok and clone aligned (no index.lock)",
       %{seed: seed, proj: proj, sync: sync} do
    commit_push!(seed, "hello.sh", "echo hi\n", "feat: hello")

    results =
      1..6
      |> Enum.map(fn _ ->
        Task.async(fn -> WorktreeSync.sync_now(sync, "fleet/myproj", "main") end)
      end)
      |> Task.await_many(30_000)

    # The GenServer serializes (one git at a time) → six concurrent alignments don't trample each other.
    assert Enum.all?(results, &(&1 == :ok))
    assert head(proj) == head(seed)
  end

  test "the DOC face REBASES: a local commit survives the remote advancing", %{
    seed: seed,
    doc: doc,
    sync: sync
  } do
    # An unpushed workshop commit distinguishes rebase from reset: both local and
    # remotely merged files must survive. This does not exercise autostash conflicts.
    git_in!(doc, ["config", "user.email", "t@lcars"])
    File.write!(Path.join(doc, "local-note.md"), "written by the arch, not yet pushed\n")
    git_in!(doc, ["add", "-A"])
    git_in!(doc, ["commit", "-qm", "docs: arch note"])

    # the forge advances on workshop (a scribe's PR merged)
    git_in!(seed, ["checkout", "-q", "workshop"])
    File.write!(Path.join(seed, "spec-notes.md"), "merged from a PR\n")
    git_in!(seed, ["add", "-A"])
    git_in!(seed, ["commit", "-qm", "docs: merged deliverable"])
    git_in!(seed, ["push", "-q", "origin", "workshop"])

    assert :ok = WorktreeSync.sync_now(sync, "fleet/myproj", "workshop")

    assert File.exists?(Path.join(doc, "spec-notes.md")),
           "the merged deliverable must have landed"

    assert File.exists?(Path.join(doc, "local-note.md")),
           "the arch's unpushed commit was ERASED — this face is a writer, it rebases, it never resets"
  end

  test "fetch_issue_refs: the ticket's branches become READABLE under a named ref per role", %{
    seed: seed,
    proj: proj,
    sync: sync
  } do
    # Fetch host-side so a read-only architect mount can inspect issue branches.
    git_in!(seed, ["checkout", "-q", "-b", "lcars/issue-7-engineer"])
    File.write!(Path.join(seed, "delivered.ex"), "def hello, do: :world\n")
    git_in!(seed, ["add", "-A"])
    git_in!(seed, ["commit", "-qm", "feat: the deliverable"])
    git_in!(seed, ["push", "-q", "origin", "lcars/issue-7-engineer"])
    git_in!(seed, ["checkout", "-q", "main"])

    assert {:ok, ["refs/lcars/pr/7/engineer"]} =
             WorktreeSync.fetch_issue_refs(sync, "fleet/myproj", 7)

    # Named refs survive unrelated FETCH_HEAD updates.
    assert {_sha, 0} =
             System.cmd("git", ["-C", proj, "rev-parse", "--verify", "refs/lcars/pr/7/engineer"])

    # Verify the expected file contents, beyond merely resolving a ref name.
    {show, 0} = System.cmd("git", ["-C", proj, "show", "refs/lcars/pr/7/engineer:delivered.ex"])
    assert show =~ "def hello"
  end

  test "fetch_issue_refs: a REWRITTEN branch moves the ref — the arch never re-reads the old one",
       %{
         seed: seed,
         proj: proj,
         sync: sync
       } do
    # Re-fetch after an amended branch and check updated content. This fixture
    # checks the result, not whether removing --force would fail for this ref namespace.
    git_in!(seed, ["checkout", "-q", "-b", "lcars/issue-8-engineer"])
    File.write!(Path.join(seed, "d.ex"), "first attempt\n")
    git_in!(seed, ["add", "-A"])
    git_in!(seed, ["commit", "-qm", "feat: v1"])
    git_in!(seed, ["push", "-q", "origin", "lcars/issue-8-engineer"])

    assert {:ok, ["refs/lcars/pr/8/engineer"]} =
             WorktreeSync.fetch_issue_refs(sync, "fleet/myproj", 8)

    {v1, 0} = System.cmd("git", ["-C", proj, "show", "refs/lcars/pr/8/engineer:d.ex"])
    assert v1 =~ "first attempt"

    # The rework: history REWRITTEN, not appended.
    File.write!(Path.join(seed, "d.ex"), "reworked after review\n")
    git_in!(seed, ["add", "-A"])
    git_in!(seed, ["commit", "-q", "--amend", "-m", "feat: v2"])
    git_in!(seed, ["push", "-qf", "origin", "lcars/issue-8-engineer"])
    git_in!(seed, ["checkout", "-q", "main"])

    assert {:ok, ["refs/lcars/pr/8/engineer"]} =
             WorktreeSync.fetch_issue_refs(sync, "fleet/myproj", 8)

    {v2, 0} = System.cmd("git", ["-C", proj, "show", "refs/lcars/pr/8/engineer:d.ex"])

    assert v2 =~ "reworked after review",
           "the ref still points at the pre-rework deliverable — the arch would judge dead code"
  end

  test "fetch_issue_refs: a ticket with NO branch answers an empty list, never an error", %{
    sync: sync
  } do
    # Empty issue refs and failure to read a local clone are different results.
    # This fixture starts with no stale refs for the issue.
    assert {:ok, []} = WorktreeSync.fetch_issue_refs(sync, "fleet/myproj", 99)
  end

  test "fetch_issue_refs: no local clone → a NAMED error, so the mandate can say so", %{
    sync: sync
  } do
    assert {:error, {:no_local_clone, _}} =
             WorktreeSync.fetch_issue_refs(sync, "fleet/jamais-clone", 7)
  end

  test "a branch that is NOT a face aligns NOTHING and says so — never the code worktree by default",
       %{proj: proj, sync: sync} do
    # A non-face branch must not route to the default code aligner.
    before = head(proj)

    assert {:error, {:not_a_face, "lcars/issue-3-scribe"}} =
             WorktreeSync.sync_now(sync, "fleet/myproj", "lcars/issue-3-scribe")

    assert head(proj) == before, "a non-face branch must not have touched a worktree"
  end

  defp commit_push!(dir, file, content, msg) do
    File.write!(Path.join(dir, file), content)
    git_in!(dir, ["add", "-A"])
    git_in!(dir, ["commit", "-m", msg])
    git_in!(dir, ["push", "origin", "main"])
  end

  defp git!(args), do: {_, 0} = System.cmd("git", args, stderr_to_stdout: true)

  defp git_in!(dir, args),
    do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp head(dir),
    do: System.cmd("git", ["-C", dir, "rev-parse", "HEAD"]) |> elem(0) |> String.trim()
end
