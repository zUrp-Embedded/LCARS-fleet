defmodule Fleet.Workflow.BriefArtifactTest do
  @moduledoc """
  The brief as a committed object whose IDENTITY is the introducing COMMIT sha. A real temp
  git repo (`git init`) — `BriefArtifact` commits for real (via `OpsObject`, exercised
  through here); we verify the object, the commit identity and the git-native idempotence.
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

  test "hintless: writes briefs/<sha256-name>.md, returns {ref, sha} with sha = the introducing COMMIT",
       %{tmp_dir: tmp} do
    git_init(tmp)
    content = "Brief: do X.\n"
    name = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    assert {:ok, %{ref: ref, sha: sha}} = BriefArtifact.commit(tmp, content)
    assert ref == "briefs/#{name}.md"
    assert File.read!(Path.join(tmp, ref)) == content
    # sha = the COMMIT that introduced the object (the version's identity), i.e. HEAD here.
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
    assert sha == String.trim(head)
    assert sha =~ ~r/\A[0-9a-f]{40}\z/
  end

  test "name_hint: plain human path briefs/issue-<n>-<role>.md; same content → same identity, no new commit",
       %{tmp_dir: tmp} do
    git_init(tmp)
    content = "Brief: do X.\n"

    assert {:ok, %{ref: ref, sha: sha}} =
             BriefArtifact.commit(tmp, content, name_hint: "issue-3-engineer")

    assert ref == "briefs/issue-3-engineer.md"
    assert File.read!(Path.join(tmp, ref)) == content
    n = commit_count(tmp)

    assert {:ok, %{ref: ^ref, sha: ^sha}} =
             BriefArtifact.commit(tmp, content, name_hint: "issue-3-engineer")

    assert commit_count(tmp) == n
  end

  test "UPDATE: different content on the SAME path → new commit (a version), old version stays at its commit",
       %{tmp_dir: tmp} do
    git_init(tmp)

    {:ok, %{ref: ref, sha: c1}} = BriefArtifact.commit(tmp, "v1\n", name_hint: "issue-3-engineer")

    {:ok, %{ref: ^ref, sha: c2}} =
      BriefArtifact.commit(tmp, "v2\n", name_hint: "issue-3-engineer")

    refute c1 == c2
    assert File.read!(Path.join(tmp, ref)) == "v2\n"
    # the validated version is readable FOREVER at its own commit (git history = the ledger).
    {old, 0} = System.cmd("git", ["show", "#{c1}:#{ref}"], cd: tmp)
    assert old == "v1\n"
  end

  test "kind judge → routed under gate-briefs/ (never mixed with worker briefs)", %{tmp_dir: tmp} do
    git_init(tmp)

    assert {:ok, %{ref: ref}} =
             BriefArtifact.commit(tmp, "judge order\n",
               name_hint: "issue-3-consultant",
               kind: "judge"
             )

    assert ref == "gate-briefs/issue-3-consultant.md"
  end

  test "name_hint sanitized (Layout truth): path-unsafe chars never reach the object path", %{
    tmp_dir: tmp
  } do
    git_init(tmp)

    assert {:ok, %{ref: ref}} = BriefArtifact.commit(tmp, "x\n", name_hint: "issue-3-a/b c")
    assert ref == "briefs/issue-3-a-b-c.md"
  end

  test "push is BEST-EFFORT: unreachable remote → commit still {:ok}, object committed locally",
       %{tmp_dir: tmp} do
    git_init(tmp)

    # `:work_ops` resolves to origin/work-ops — no such remote in this repo → Git.push fails;
    # the materialization must NOT (F-15: local commit = base truth, publication degrades LOUD).
    assert {:ok, %{ref: ref}} = BriefArtifact.commit(tmp, "pushed brief\n", push: :work_ops)

    assert File.exists?(Path.join(tmp, ref))
    assert {_, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
  end

  test "default author = the SYSTEM identity SSoT (forge-linkable email, never a retyped literal)",
       %{tmp_dir: tmp} do
    git_init(tmp)
    {:ok, %{sha: sha}} = BriefArtifact.commit(tmp, "attributed\n")

    {out, 0} = System.cmd("git", ["show", "-s", "--format=%an <%ae>", sha], cd: tmp)
    expected = Fleet.Credentials.ForgeIdentity.system_identity()
    # Gitea links a commit to a profile by EMAIL match — a divergent literal here renders
    # every work-order/provenance commit as plain text (no link, no avatar) on the forge.
    assert String.trim(out) == "#{expected.name} <#{expected.email}>"
  end

  test "idempotence: same content re-committed → same {ref, sha}, ZERO new commit", %{
    tmp_dir: tmp
  } do
    git_init(tmp)
    content = "identical\n"

    {:ok, r1} = BriefArtifact.commit(tmp, content)
    n1 = commit_count(tmp)
    {:ok, r2} = BriefArtifact.commit(tmp, content)
    n2 = commit_count(tmp)

    assert r1 == r2
    assert n2 == n1, "re-briefing identical content must NOT re-commit (git-native idempotence)"
  end

  test "DIFFERENT hintless content → different ref and different identity", %{tmp_dir: tmp} do
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

  test "physicalize_attrs: commits the object + adds brief_ref/brief_sha, attrs preserved", %{
    tmp_dir: tmp
  } do
    # the 'fleet/demo' project work/ops = <work_root>/demo
    work_dir = Path.join(tmp, "demo")
    File.mkdir_p!(work_dir)
    git_init(work_dir)

    out =
      BriefArtifact.physicalize_attrs(%{brief: "do X\n", role: "engineer"}, "fleet/demo",
        work_root: tmp
      )

    assert out.role == "engineer"
    # brief_sha = the introducing COMMIT (40 hex); the hintless ref is named by content sha256.
    assert out.brief_sha =~ ~r/\A[0-9a-f]{40}\z/
    name = :crypto.hash(:sha256, "do X\n") |> Base.encode16(case: :lower)
    assert out.brief_ref == "briefs/#{name}.md"
    assert File.read!(Path.join(work_dir, out.brief_ref)) == "do X\n"
  end

  test "physicalize_attrs: DEGRADES (attrs unchanged) when the project work/ops does not exist",
       %{tmp_dir: tmp} do
    attrs = %{brief: "x\n", role: "engineer"}
    # <work_root>/demo missing → degrades, dispatch preserved, no brief_ref/brief_sha.
    assert BriefArtifact.physicalize_attrs(attrs, "fleet/demo", work_root: tmp) == attrs
  end

  test "physicalize_attrs: nothing to materialize (no brief / nil repo / empty brief) → unchanged" do
    assert BriefArtifact.physicalize_attrs(%{role: "x"}, "fleet/demo") == %{role: "x"}
    assert BriefArtifact.physicalize_attrs(%{brief: "y"}, nil) == %{brief: "y"}
    assert BriefArtifact.physicalize_attrs(%{brief: ""}, "fleet/demo") == %{brief: ""}
  end

  test "pointer_brief: the SHORT payload order — names the doc, the sha7, and commands READ-first" do
    sha = (String.duplicate("a1b2c3d", 5) <> "a1b2c") |> String.slice(0, 40)
    order = BriefArtifact.pointer_brief("briefs/issue-9-engineer.md", sha)

    assert order =~ "briefs/issue-9-engineer.md"
    assert order =~ String.slice(sha, 0, 7)
    assert order =~ "LIS-le EN PREMIER"
    assert order =~ "${LCARS_PROJECT_OPS}/briefs/issue-9-engineer.md"
    # SHORT is the point: a pointer, not an inline blob.
    assert String.length(order) < 400
  end

  test "commit inside an orphan git WORKTREE (the REAL work/ops: `.git` is a FILE, not a dir)",
       %{tmp_dir: tmp} do
    # Live regression: `git init` (`.git` = dir) passed, but the real work/ops is an orphan git
    # WORKTREE (ProjectOnboard `git worktree add --orphan`) whose `.git` is a FILE →
    # `ensure_git_workspace` rejected it (`:not_a_git_workspace`) → brief never committed. This test
    # walks the REAL case, not the plausible one.
    main = Path.join(tmp, "main")
    File.mkdir_p!(main)

    g = fn args ->
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args], cd: main)
    end

    {_, 0} = g.(["init", "-q"])
    File.write!(Path.join(main, "README"), "x")
    {_, 0} = g.(["add", "."])
    {_, 0} = g.(["commit", "-qm", "init"])

    wt = Path.join(tmp, "workops")
    # `worktree add --orphan` needs git >= 2.42; Debian bookworm (the container's base, and the
    # image that runs this gate) ships 2.39 and answers exit 129. The two-step below builds the
    # SAME shape on every version — a worktree whose `.git` is a FILE, on an orphan branch — so
    # the case under test is unchanged and the gate stops depending on the runner's git.
    case g.(["worktree", "add", "--orphan", "-b", "work/ops", wt]) do
      {_, 0} ->
        :ok

      {_, _} ->
        {_, 0} = g.(["worktree", "add", "--detach", wt])

        {_, 0} =
          System.cmd(
            "git",
            ["-c", "user.name=t", "-c", "user.email=t@t", "checkout", "--orphan", "work/ops"],
            cd: wt
          )
    end

    # THE point: in a worktree, `.git` is a FILE (`gitdir: …`), not a directory.
    assert File.regular?(Path.join(wt, ".git"))

    assert {:ok, %{ref: ref, sha: sha}} = BriefArtifact.commit(wt, "brief in a worktree\n")
    assert File.read!(Path.join(wt, ref)) == "brief in a worktree\n"
    assert sha =~ ~r/\A[0-9a-f]{40}\z/
    # committed FOR REAL inside the worktree (the bug returned `{nil, nil}` with no commit).
    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: wt)
    assert log =~ "brief: #{ref}"
  end
end
