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

  # ── A writer face ALSO moves without a merge: the deck's deposit door commits on the forge ──

  test "DEPOSIT: a commit landed on the forge's workshop WITHOUT a merge reaches the face at refresh",
       %{seed: seed, doc: doc, sync: sync} do
    deposit!(seed, "ready-room/passation.zip", "PK\x03\x04")
    refute File.exists?(Path.join(doc, "ready-room/passation.zip"))

    WorktreeSync.refresh(sync, "fleet/myproj", "workshop")
    # A call behind the cast: the GenServer serializes, so the refresh has run.
    _ = :sys.get_state(sync)

    assert File.exists?(Path.join(doc, "ready-room/passation.zip")),
           "the deposited file must be on the face — where the architect's pod sees it"

    assert head(doc) == remote_head(seed, "workshop")
  end

  test "refresh leaves a face that has EVERYTHING untouched — no fetch, the live tree is not stashed",
       %{doc: doc, sync: sync} do
    # The architect edits this face live; rebasing it every tick for nothing would race its editor.
    File.write!(Path.join(doc, "in-progress.md"), "half written\n")
    before = head(doc)

    WorktreeSync.refresh(sync, "fleet/myproj", "workshop")
    _ = :sys.get_state(sync)

    refute File.exists?(Path.join(doc, ".git/FETCH_HEAD")),
           "an up-to-date face must be settled by ls-remote alone, never by a fetch"

    assert head(doc) == before
    assert File.read!(Path.join(doc, "in-progress.md")) == "half written\n"
  end

  test "refresh keeps the architect's unpushed commit AND brings the deposit down (rebase, not reset)",
       %{seed: seed, doc: doc, sync: sync} do
    File.write!(Path.join(doc, "note-arch.md"), "not pushed yet\n")
    git_in!(doc, ["add", "-A"])
    git_in!(doc, ["commit", "-qm", "docs: arch"])
    deposit!(seed, "ready-room/passation.zip", "PK")

    WorktreeSync.refresh(sync, "fleet/myproj", "workshop")
    _ = :sys.get_state(sync)

    assert File.exists?(Path.join(doc, "ready-room/passation.zip"))
    assert File.exists?(Path.join(doc, "note-arch.md"))
  end

  test "refresh on the CODE branch touches nothing — its aligner resets, it is not a writer face",
       %{seed: seed, proj: proj, sync: sync} do
    before = head(proj)
    commit_push!(seed, "hello.sh", "echo hi\n", "feat: hello")

    WorktreeSync.refresh(sync, "fleet/myproj", "main")
    _ = :sys.get_state(sync)

    assert head(proj) == before
  end

  test "align_before_push brings the deposit down, through the server or inline without one",
       %{seed: seed, doc: doc, sync: sync} do
    deposit!(seed, "ready-room/a.bin", "a")
    assert :ok = WorktreeSync.align_before_push(sync, doc, "workshop")
    assert File.exists?(Path.join(doc, "ready-room/a.bin"))
    assert :up_to_date = WorktreeSync.align_before_push(sync, doc, "workshop")

    # No server under that name (a test, a runtime still booting): the same act, inline.
    deposit!(seed, "ready-room/b.bin", "b")

    assert :ok =
             WorktreeSync.align_before_push(:"absent_#{System.unique_integer()}", doc, "workshop")

    assert File.exists?(Path.join(doc, "ready-room/b.bin"))
  end

  # ── A face whose writer is in the middle of something is REFUSED, never clobbered ──
  # Measured with git 2.53: `rebase --autostash` exits 0 when the stash does not re-apply, and
  # leaves conflict markers in the writer's file. Each case below would pass for success without
  # the guard.

  test "an UNCOMMITTED edit on a path the forge changed: refused, the edit intact, no stash",
       %{seed: seed, doc: doc, sync: sync} do
    File.write!(Path.join(doc, "backlog.md"), "the arch is editing\n")
    deposit!(seed, "backlog.md", "replaced on the forge\n")
    before = head(doc)

    assert {:error, {:local_work_in_the_way, "workshop", ["backlog.md"]}} =
             WorktreeSync.align_before_push(sync, doc, "workshop")

    assert File.read!(Path.join(doc, "backlog.md")) == "the arch is editing\n"
    assert head(doc) == before
    assert git_out(doc, ["stash", "list"]) == ""
  end

  test "an UNTRACKED file on the deposited path: refused, the local file intact",
       %{seed: seed, doc: doc, sync: sync} do
    File.mkdir_p!(Path.join(doc, "ready-room"))
    File.write!(Path.join(doc, "ready-room/p.zip"), "local")
    deposit!(seed, "ready-room/p.zip", "deposited")

    assert {:error, {:local_work_in_the_way, "workshop", ["ready-room/p.zip"]}} =
             WorktreeSync.align_before_push(sync, doc, "workshop")

    assert File.read!(Path.join(doc, "ready-room/p.zip")) == "local"
  end

  test "an IGNORED file on the deposited path is not overwritten either",
       %{seed: seed, doc: doc, sync: sync} do
    File.write!(Path.join(doc, ".git/info/exclude"), "*.bin\n")
    File.mkdir_p!(Path.join(doc, "ready-room"))
    File.write!(Path.join(doc, "ready-room/fw.bin"), "local build")
    deposit!(seed, "ready-room/fw.bin", "deposited")

    assert {:error, {:local_work_in_the_way, "workshop", ["ready-room/fw.bin"]}} =
             WorktreeSync.align_before_push(sync, doc, "workshop")

    assert File.read!(Path.join(doc, "ready-room/fw.bin")) == "local build"
  end

  test "a local COMMIT that conflicts with the forge: rebase aborted, the commit kept, nothing half-done",
       %{seed: seed, doc: doc, sync: sync} do
    File.write!(Path.join(doc, "backlog.md"), "arch commit\n")
    git_in!(doc, ["commit", "-qam", "docs: arch"])
    before = head(doc)
    deposit!(seed, "backlog.md", "forge commit\n")

    assert {:error, {:rebase_conflict, "workshop", _}} =
             WorktreeSync.align_before_push(sync, doc, "workshop")

    assert head(doc) == before
    assert File.read!(Path.join(doc, "backlog.md")) == "arch commit\n"
    refute File.exists?(Path.join(doc, ".git/rebase-merge"))
    refute File.exists?(Path.join(doc, ".git/rebase-apply"))
  end

  test "refresh remembers a refused face, and forgets it once the face follows again",
       %{seed: seed, doc: doc, sync: sync} do
    File.write!(Path.join(doc, "backlog.md"), "the arch is editing\n")
    deposit!(seed, "backlog.md", "replaced on the forge\n")

    WorktreeSync.refresh(sync, "fleet/myproj", "workshop")
    assert MapSet.member?(:sys.get_state(sync).refresh_failed, "fleet/myproj")

    git_in!(doc, ["checkout", "--", "backlog.md"])
    WorktreeSync.refresh(sync, "fleet/myproj", "workshop")
    refute MapSet.member?(:sys.get_state(sync).refresh_failed, "fleet/myproj")
    assert File.read!(Path.join(doc, "backlog.md")) == "replaced on the forge\n"
  end

  defp git_out(dir, args),
    do: System.cmd("git", ["-C", dir | args]) |> elem(0) |> String.trim()

  # What the deposit door does through the forge's content API: one commit on workshop, no PR.
  defp deposit!(seed, rel, content) do
    git_in!(seed, ["checkout", "-q", "workshop"])
    File.mkdir_p!(Path.dirname(Path.join(seed, rel)))
    File.write!(Path.join(seed, rel), content)
    git_in!(seed, ["add", "-A"])
    git_in!(seed, ["commit", "-qm", "depot(captain): " <> Path.basename(rel)])
    git_in!(seed, ["push", "-q", "origin", "workshop"])
    git_in!(seed, ["checkout", "-q", "main"])
  end

  defp remote_head(seed, branch),
    do:
      System.cmd("git", ["-C", seed, "rev-parse", "origin/" <> branch])
      |> elem(0)
      |> String.trim()

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
