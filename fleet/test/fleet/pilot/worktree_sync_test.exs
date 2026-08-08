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
    doc_root = Path.join(tmp, "projects.doc")
    File.mkdir_p!(doc_root)
    git_in!(seed, ["checkout", "-q", "--orphan", "work/doc"])
    git_in!(seed, ["rm", "-rq", "--cached", "."])
    File.write!(Path.join(seed, "backlog.md"), "v0\n")
    git_in!(seed, ["add", "-A"])
    git_in!(seed, ["commit", "-qm", "init doc"])
    git_in!(seed, ["push", "-q", "origin", "work/doc"])
    git_in!(seed, ["checkout", "-q", "main"])
    doc = Path.join(doc_root, "myproj")
    git!(["clone", "-q", "--branch", "work/doc", origin, doc])
    git_in!(doc, ["config", "user.email", "t@lcars"])
    git_in!(doc, ["config", "user.name", "t"])

    # unique name → async tests without collision on the GenServer's global name.
    name = :"wt_#{System.unique_integer([:positive])}"
    start_supervised!({WorktreeSync, name: name, projects_root: root, doc_root: doc_root})

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

    # the forge advances on work/doc (a scribe's PR merged)
    git_in!(seed, ["checkout", "-q", "work/doc"])
    File.write!(Path.join(seed, "spec-notes.md"), "merged from a PR\n")
    git_in!(seed, ["add", "-A"])
    git_in!(seed, ["commit", "-qm", "docs: merged deliverable"])
    git_in!(seed, ["push", "-q", "origin", "work/doc"])

    assert :ok = WorktreeSync.sync_now(sync, "fleet/myproj", "work/doc")

    assert File.exists?(Path.join(doc, "spec-notes.md")),
           "the merged deliverable must have landed"

    assert File.exists?(Path.join(doc, "local-note.md")),
           "the arch's unpushed commit was ERASED — this face is a writer, it rebases, it never resets"
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
