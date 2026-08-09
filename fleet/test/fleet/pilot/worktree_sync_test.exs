defmodule Fleet.Pilot.WorktreeSyncTest do
  @moduledoc """
  `WorktreeSync` REALLY aligns the local clone on `origin/main` — real git (local bare origin +
  clone + advancement), not a stub. This is the anti-hollow-green of the fix: without alignment, the
  delivered file never appears on disk (the original bug). `origin` is a local path → no network, no
  token (the `fetch auth:true` goes through `ForgeAuth.git_env() == []` in test, inert on a local
  remote).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.WorktreeSync

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

    # the DOC face: an orphan branch on the same origin, cloned into its own root. Its clone is a
    # WRITER (the architect and the human author in it), which is the property the alignment turns on.
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

    start_supervised!(
      {WorktreeSync, name: name, projects_root: root, workshop_root: workshop_root}
    )

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
    # THE DESTRUCTIVE MUTATION, and nothing caught it: aligning `doc` with the code face's
    # `reset --hard` left the whole suite green (measured 2026-08-08). It would have to — every
    # other fixture here is on `main`, where reset IS right because nobody writes locally.
    #
    # On `doc` somebody does: the architect and the human author in that clone, and a merge landing
    # on the forge would then silently erase whatever they had committed but not yet pushed. A reset
    # does not fail on the work it destroys; it reports `:ok`.
    #
    # The discriminator is a local commit that the remote has never seen. Reset drops it. Rebase
    # replays it on top of the merged tip — both survive, which is what this asserts.
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
    # WHY THIS EXISTS. The architect's code face is a read-only bind, so its own `git fetch` dies on
    # `.git/FETCH_HEAD` — and what that cost was NOT the missing diff: it arbitrated anyway and
    # invented an explanation for code it could not see. The fetch runs host-side, here, in the
    # worktree this GenServer already serializes; the pod only reads the result.
    git_in!(seed, ["checkout", "-q", "-b", "lcars/issue-7-engineer"])
    File.write!(Path.join(seed, "delivered.ex"), "def hello, do: :world\n")
    git_in!(seed, ["add", "-A"])
    git_in!(seed, ["commit", "-qm", "feat: the deliverable"])
    git_in!(seed, ["push", "-q", "origin", "lcars/issue-7-engineer"])
    git_in!(seed, ["checkout", "-q", "main"])

    assert {:ok, ["refs/lcars/pr/7/engineer"]} =
             WorktreeSync.fetch_issue_refs(sync, "fleet/myproj", 7)

    # NAMED, not `FETCH_HEAD`: the next fetch overwrites that file and it never says what it is the
    # head OF. This ref is stable, self-describing, and readable by the pod through its RO bind.
    assert {_sha, 0} =
             System.cmd("git", ["-C", proj, "rev-parse", "--verify", "refs/lcars/pr/7/engineer"])

    # And the CONTENT is there — a ref that resolves to nothing would satisfy the assertion above
    # while leaving the arch exactly as blind.
    {show, 0} = System.cmd("git", ["-C", proj, "show", "refs/lcars/pr/7/engineer:delivered.ex"])
    assert show =~ "def hello"
  end

  test "fetch_issue_refs: a REWRITTEN branch moves the ref — the arch never re-reads the old one",
       %{
         seed: seed,
         proj: proj,
         sync: sync
       } do
    # THE `--force`, and nothing held it: dropping it left the whole suite green (measured
    # 2026-08-08), because the other fixture pushes its branch exactly once.
    #
    # A producer that REWORKS force-pushes: amend, rebase, squash — the branch moves
    # non-fast-forward. Without `--force` the local ref REFUSES the update, and the fetch reports
    # nothing wrong. The arch then reads the PREVIOUS deliverable under a ref that names the
    # current ticket, and arbitrates on code that no longer exists — the exact failure this whole
    # gesture exists to end, re-created one layer down.
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
    # The distinction the mandate renders differently: "nothing to read, the escalation is about
    # something else" is not "the deliverable could not be made readable". Collapsing the two would
    # make the arch defer on a ticket that never had code.
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
    # THE FALL-THROUGH IS THE DANGEROUS CLAUSE, and nothing held it: replacing the explicit
    # non-face branch with a catch-all onto the code worktree left the whole suite green (measured
    # 2026-08-08). A feature branch handed here would then have been silently reset onto a face it
    # does not belong to — the alignment is `reset --hard` on the code side, so the wrong guess
    # does not fail, it DESTROYS, and it reports `:ok`.
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
