defmodule Fleet.Workflow.BriefArtifactTest do
  @moduledoc """
  Local temporary Git repositories exercise commit identity, version reuse and worktree support
  through BriefArtifact. OpsObject supplies author env, so git init needs no identity config.
  These tests do not establish remote availability or serializer concurrency behavior.
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
    # First commit in this fixture: the returned version must be HEAD.
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
    assert sha == String.trim(head)
    assert sha =~ ~r/\A[0-9a-f]{40}\z/
  end

  test "PROVENANCE lives in git: the introducing commit's MESSAGE names the object (transport_brief_v2)",
       %{tmp_dir: tmp} do
    # The commit message must identify the object for audit through Git history.
    git_init(tmp)

    assert {:ok, %{ref: ref, sha: sha}} =
             BriefArtifact.commit(tmp, "Brief: do X.\n", name_hint: "issue-7-engineer")

    {msg, 0} = System.cmd("git", ["log", "-1", "--format=%s", sha], cd: tmp)
    # Removing ref from OpsObject's commit message was caught by this assertion under mutation.
    assert String.trim(msg) =~ ref
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
    # The old version remains readable in this repository's retained history.
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

    # F-15: missing origin makes publication local_only without discarding the committed object.
    assert {:ok, %{ref: ref, push: :local_only}} =
             BriefArtifact.commit(tmp, "pushed brief\n", push: :ops)

    assert File.exists?(Path.join(tmp, ref))
    assert {_, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
  end

  test "no `:push` opt is NOT a failed push — the two are different answers", %{tmp_dir: tmp} do
    git_init(tmp)

    # Distinguish no publication requested from an unsuccessful publication attempt.
    assert {:ok, %{push: :not_requested}} = BriefArtifact.commit(tmp, "unpushed\n")
  end

  test "default author = the SYSTEM identity SSoT (forge-linkable email, never a retyped literal)",
       %{tmp_dir: tmp} do
    git_init(tmp)
    {:ok, %{sha: sha}} = BriefArtifact.commit(tmp, "attributed\n")

    {out, 0} = System.cmd("git", ["show", "-s", "--format=%an <%ae>", sha], cd: tmp)
    expected = Fleet.Credentials.ForgeIdentity.system_identity()
    # Keep local attribution aligned with the account identity used for forge email linking.
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
    # the 'fleet/demo' project ops = <ops_root>/demo
    work_dir = Path.join(tmp, "demo")
    File.mkdir_p!(work_dir)
    git_init(work_dir)

    out =
      BriefArtifact.physicalize_attrs(%{brief: "do X\n", role: "engineer"}, "fleet/demo",
        ops_root: tmp
      )

    assert out.role == "engineer"
    # brief_sha = the introducing COMMIT (40 hex); the hintless ref is named by content sha256.
    assert out.brief_sha =~ ~r/\A[0-9a-f]{40}\z/
    name = :crypto.hash(:sha256, "do X\n") |> Base.encode16(case: :lower)
    assert out.brief_ref == "briefs/#{name}.md"
    assert File.read!(Path.join(work_dir, out.brief_ref)) == "do X\n"
  end

  test "physicalize_attrs: DEGRADES (attrs unchanged) when the project ops does not exist",
       %{tmp_dir: tmp} do
    attrs = %{brief: "x\n", role: "engineer"}
    # <ops_root>/demo missing → degrades, dispatch preserved, no brief_ref/brief_sha.
    assert BriefArtifact.physicalize_attrs(attrs, "fleet/demo", ops_root: tmp) == attrs
  end

  test "physicalize_attrs: nothing to materialize (no brief / nil repo / empty brief) → unchanged" do
    assert BriefArtifact.physicalize_attrs(%{role: "x"}, "fleet/demo") == %{role: "x"}
    assert BriefArtifact.physicalize_attrs(%{brief: "y"}, nil) == %{brief: "y"}
    assert BriefArtifact.physicalize_attrs(%{brief: ""}, "fleet/demo") == %{brief: ""}
  end

  describe "materialize/3 — the cause, not just the failure" do
    # Keep materialize's causes available for caller policy; physicalize deliberately flattens them.
    test "names the four causes apart" do
      assert {:error, :no_brief} = BriefArtifact.materialize(nil, "fleet/demo")
      assert {:error, :no_brief} = BriefArtifact.materialize("", "fleet/demo")
      assert {:error, :no_repo} = BriefArtifact.materialize("x", nil)
      assert {:error, :no_repo} = BriefArtifact.materialize("x", "")
    end

    test "an un-onboarded project is named as such, not as a git failure", %{tmp_dir: tmp} do
      # Missing directory has its own cause; this fixture does not establish prior onboarding state.
      assert {:error, {:work_dir_missing, _}} =
               BriefArtifact.materialize("x\n", "fleet/demo", ops_root: tmp)
    end

    test "and the happy path returns the pair the pointer is built from", %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "demo")
      File.mkdir_p!(work_dir)
      git_init(work_dir)

      assert {:ok, {ref, sha}} =
               BriefArtifact.materialize("do X\n", "fleet/demo", ops_root: tmp)

      assert sha =~ ~r/\A[0-9a-f]{40}\z/
      assert String.starts_with?(ref, "briefs/")
    end
  end

  test "commit inside an orphan git WORKTREE (the REAL ops: `.git` is a FILE, not a dir)",
       %{tmp_dir: tmp} do
    # Regression: .git is a file in an ops worktree, previously rejected as not_a_git_workspace.
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
    # Older Git (bench: bookworm 2.39, exit 129) lacked worktree add --orphan.
    # The fallback still exercises a .git file on an orphan branch, though initial index differs.
    case g.(["worktree", "add", "--orphan", "-b", "ops", wt]) do
      {_, 0} ->
        :ok

      {_, _} ->
        {_, 0} = g.(["worktree", "add", "--detach", wt])

        {_, 0} =
          System.cmd(
            "git",
            ["-c", "user.name=t", "-c", "user.email=t@t", "checkout", "--orphan", "ops"],
            cd: wt
          )
    end

    assert File.regular?(Path.join(wt, ".git"))

    assert {:ok, %{ref: ref, sha: sha}} = BriefArtifact.commit(wt, "brief in a worktree\n")
    assert File.read!(Path.join(wt, ref)) == "brief in a worktree\n"
    assert sha =~ ~r/\A[0-9a-f]{40}\z/
    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: wt)
    assert log =~ "brief: #{ref}"
  end
end
