defmodule Fleet.Workflow.BriefArtifactTest do
  @moduledoc """
  The brief as a content-addressed object. A real temp git repo (`git init`) —
  `BriefArtifact` commits for real; we verify the object + idempotence.
  The commit identity comes from the env (`GIT_AUTHOR_*`), not from the repo config → `git init` is enough.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.BriefArtifact

  @moduletag :tmp_dir

  defp git_init(dir) do
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    :ok
  end

  defp commit_count(dir) do
    {out, 0} = System.cmd("git", ["rev-list", "--count", "HEAD"], cd: dir)
    String.trim(out)
  end

  test "content-addressed: writes briefs/<sha256>.md, returns {ref, sha}, sha = sha256(content), committed",
       %{tmp_dir: tmp} do
    git_init(tmp)
    content = "Brief: do X.\n"
    expected = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    assert {:ok, %{ref: ref, sha: sha}} = BriefArtifact.commit(tmp, content)
    assert sha == expected
    assert ref == "briefs/#{sha}.md"
    assert File.read!(Path.join(tmp, ref)) == content
    # the object is COMMITTED (HEAD exists) — not just written to disk.
    assert {_, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
  end

  test "idempotence: same content re-committed → same {ref, sha}, ZERO new commit", %{tmp_dir: tmp} do
    git_init(tmp)
    content = "identical\n"

    {:ok, r1} = BriefArtifact.commit(tmp, content)
    n1 = commit_count(tmp)
    {:ok, r2} = BriefArtifact.commit(tmp, content)
    n2 = commit_count(tmp)

    assert r1 == r2
    assert n2 == n1, "re-briefing identical content must NOT re-commit (content-address = idempotence)"
  end

  test "DIFFERENT content → different sha/ref (never a content collision)", %{tmp_dir: tmp} do
    git_init(tmp)
    assert {:ok, a} = BriefArtifact.commit(tmp, "A\n")
    assert {:ok, b} = BriefArtifact.commit(tmp, "B\n")
    refute a.sha == b.sha
    refute a.ref == b.ref
  end

  test "work_dir missing → {:error, {:work_dir_missing, _}} (fail-loud)", %{tmp_dir: tmp} do
    ghost = Path.join(tmp, "does-not-exist")
    assert {:error, {:work_dir_missing, ^ghost}} = BriefArtifact.commit(ghost, "x")
  end

  test "physicalize_attrs: commits the object + adds brief_ref/brief_sha, attrs preserved", %{tmp_dir: tmp} do
    # the 'fleet/demo' project work/ops = <work_root>/demo
    work_dir = Path.join(tmp, "demo")
    File.mkdir_p!(work_dir)
    git_init(work_dir)

    out = BriefArtifact.physicalize_attrs(%{brief: "do X\n", role: "engineer"}, "fleet/demo", work_root: tmp)

    assert out.role == "engineer"
    assert is_binary(out.brief_sha)
    assert out.brief_ref == "briefs/#{out.brief_sha}.md"
    assert File.read!(Path.join(work_dir, out.brief_ref)) == "do X\n"
  end

  test "physicalize_attrs: DEGRADES (attrs unchanged) when the project work/ops does not exist", %{tmp_dir: tmp} do
    attrs = %{brief: "x\n", role: "engineer"}
    # <work_root>/demo missing → degrades, dispatch preserved, no brief_ref/brief_sha.
    assert BriefArtifact.physicalize_attrs(attrs, "fleet/demo", work_root: tmp) == attrs
  end

  test "physicalize_attrs: nothing to materialize (no brief / nil repo / empty brief) → unchanged" do
    assert BriefArtifact.physicalize_attrs(%{role: "x"}, "fleet/demo") == %{role: "x"}
    assert BriefArtifact.physicalize_attrs(%{brief: "y"}, nil) == %{brief: "y"}
    assert BriefArtifact.physicalize_attrs(%{brief: ""}, "fleet/demo") == %{brief: ""}
  end

  test "commit inside an orphan git WORKTREE (the REAL work/ops: `.git` is a FILE, not a dir)",
       %{tmp_dir: tmp} do
    # Live regression: `git init` (`.git` = dir) passed, but the real work/ops is an orphan git
    # WORKTREE (ProjectOnboard `git worktree add --orphan`) whose `.git` is a FILE →
    # `ensure_git_workspace` rejected it (`:not_a_git_workspace`) → brief never committed. This test
    # walks the REAL case, not the plausible one.
    main = Path.join(tmp, "main")
    File.mkdir_p!(main)
    g = fn args -> System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args], cd: main) end
    {_, 0} = g.(["init", "-q"])
    File.write!(Path.join(main, "README"), "x")
    {_, 0} = g.(["add", "."])
    {_, 0} = g.(["commit", "-qm", "init"])

    wt = Path.join(tmp, "workops")
    {_, 0} = g.(["worktree", "add", "--orphan", "-b", "work/ops", wt])
    # THE point: in a worktree, `.git` is a FILE (`gitdir: …`), not a directory.
    assert File.regular?(Path.join(wt, ".git"))

    assert {:ok, %{ref: ref, sha: sha}} = BriefArtifact.commit(wt, "brief in a worktree\n")
    assert File.read!(Path.join(wt, ref)) == "brief in a worktree\n"
    # committed FOR REAL inside the worktree (the bug returned `{nil, nil}` with no commit).
    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: wt)
    assert log =~ "brief: briefs/#{sha}.md"
  end
end
