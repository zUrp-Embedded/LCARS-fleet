defmodule Fleet.GitTest do
  alias Fleet.Workflow.Git

  # Mutates the shared :workflow_git_push_runner application setting.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  # ============================================================
  # Helpers (workspace + remote bare repos in tmp_dir)
  # ============================================================

  defp init_bare_repo(path) do
    File.mkdir_p!(path)
    {_out, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", path])
    path
  end

  defp init_workspace(path, opts \\ []) do
    File.mkdir_p!(path)
    {_out, 0} = System.cmd("git", ["init", "--initial-branch=main", path])

    # Identity for direct fixture Git commits, which do not use ForgeAuth.
    {_out, 0} = System.cmd("git", ["config", "user.name", "init-only"], cd: path)
    {_out, 0} = System.cmd("git", ["config", "user.email", "init@example.com"], cd: path)

    case Keyword.get(opts, :remote_url) do
      nil -> :ok
      remote -> {_out, 0} = System.cmd("git", ["remote", "add", "origin", remote], cd: path)
    end

    path
  end

  defp commit_initial(workspace, message \\ "initial") do
    File.write!(Path.join(workspace, "seed.txt"), "seed\n")
    {_out, 0} = System.cmd("git", ["add", "."], cd: workspace)
    {_out, 0} = System.cmd("git", ["commit", "-m", message], cd: workspace)
    :ok
  end

  defp valid_opts(workspace) do
    %{
      workspace: workspace,
      author_name: "engineer",
      author_email: "engineer@lcars.local",
      committer_name: "Fixture Committer",
      committer_email: "committer@fixture.test",
      message: "feat: payload from worker"
    }
  end

  # ============================================================
  # commit/1 — add+commit (no push; Deliverable's payload mode)
  # (acte4 #20: publish/1 — the legacy coupled add+commit+push path, ZERO prod callers —
  # is REMOVED; its shared cases are covered here via commit/1, the push via push/3.)
  # ============================================================

  describe "commit/1 — local commit without push" do
    test "commit created with correct author and committer (D-04)", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws"))
      commit_initial(ws)
      File.write!(Path.join(ws, "feature.md"), "delivered by worker\n")

      assert {:ok, <<_::binary-size(40)>>} = Git.commit(valid_opts(ws))

      {author_line, 0} = System.cmd("git", ["log", "-1", "--format=%an <%ae>"], cd: ws)
      {committer_line, 0} = System.cmd("git", ["log", "-1", "--format=%cn <%ce>"], cd: ws)
      {subject, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: ws)

      assert String.trim(author_line) == "engineer <engineer@lcars.local>"
      assert String.trim(committer_line) == "Fixture Committer <committer@fixture.test>"
      assert String.trim(subject) == "feat: payload from worker"
    end

    test "add_paths restricts the staging", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-paths"))
      commit_initial(ws)

      File.mkdir_p!(Path.join(ws, "docs"))
      File.write!(Path.join(ws, "docs/X.md"), "doc\n")
      File.write!(Path.join(ws, "ignored.txt"), "should not be committed\n")

      opts = Map.put(valid_opts(ws), :add_paths, ["docs/"])
      assert {:ok, _} = Git.commit(opts)

      {staged_files, 0} = System.cmd("git", ["show", "--name-only", "--format=", "HEAD"], cd: ws)
      assert String.trim(staged_files) == "docs/X.md"
    end

    test "fail-closed: missing workspace", %{tmp_dir: tmp} do
      assert {:error, :workspace_missing} =
               Git.commit(valid_opts(Path.join(tmp, "nope")))
    end

    test "fail-closed: workspace is not a git repo", %{tmp_dir: tmp} do
      ws = Path.join(tmp, "not-git")
      File.mkdir_p!(ws)

      assert {:error, :not_a_git_workspace} = Git.commit(valid_opts(ws))
    end

    test "fail-closed: nothing to commit → :nothing_to_commit", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-empty"))
      commit_initial(ws)
      # NO modification after the seed → git commit refuses.
      assert {:error, :nothing_to_commit} = Git.commit(valid_opts(ws))
    end

    test "fail-closed: missing opts", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-bad"))
      commit_initial(ws)

      opts = valid_opts(ws) |> Map.delete(:author_email) |> Map.delete(:message)
      assert {:error, {:missing_opts, missing}} = Git.commit(opts)
      assert :author_email in missing
      assert :message in missing
    end
  end

  # ============================================================
  # git injection (F-014 add / F-046 push) — Pattern C
  # ============================================================

  describe "git injection (Pattern C)" do
    test "F-014: leading-`-` add_paths is a PATH (via `--`), not an option — `--all` does not stage everything",
         %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f014"))
      commit_initial(ws)
      File.write!(Path.join(ws, "sneaky.txt"), "x\n")

      opts = Map.put(valid_opts(ws), :add_paths, ["--all"])

      # The option-like pathspec names no file; this assertion checks refusal.
      assert {:error, _} = Git.commit(opts)
    end

    test "F-014: invalid add_paths (empty / non-binary / empty element) → :invalid_add_paths",
         %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f014b"))
      commit_initial(ws)
      File.write!(Path.join(ws, "x.txt"), "x\n")

      for bad <- [[], [123], ["", "ok"], "not-a-list"] do
        opts = Map.put(valid_opts(ws), :add_paths, bad)

        assert {:error, :invalid_add_paths} = Git.commit(opts),
               "add_paths #{inspect(bad)}"
      end
    end

    test "F-046: leading-`-` push remote rejected fail-closed (`-c`, `--receive-pack=`, `--exec=`)",
         %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f046"))

      for bad <- ["-c", "--receive-pack=touch /tmp/pwn", "--exec=x"] do
        assert {:error, {:invalid_remote, ^bad}} = Git.push(ws, bad, "HEAD:main"),
               "remote #{inspect(bad)}"
      end
    end

    test "F-046: leading-`-` push refspec rejected", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f046b"))

      assert {:error, {:invalid_refspec, "--force"}} =
               Git.push(ws, "origin", "--force")
    end
  end

  # ============================================================
  # commit/1 → push/3 — the real payload chaining (CONTENT then PUBLICATION)
  # ============================================================

  describe "commit/1 then push/3 — chaining to a bare repo" do
    test "the local commit lands on the remote via push/3 (local bare repo)", %{tmp_dir: tmp} do
      bare = init_bare_repo(Path.join(tmp, "bare.git"))
      ws = init_workspace(Path.join(tmp, "ws"), remote_url: bare)
      commit_initial(ws)

      # First push to align the bare on main.
      {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: ws)

      File.write!(Path.join(ws, "feature.md"), "post-extract payload\n")

      assert {:ok, sha} = Git.commit(valid_opts(ws))
      # commit/1 does NOT touch the remote (content/publication separation)…
      {bare_head, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      refute String.trim(bare_head) == sha

      # …push/3 is what publishes.
      assert {:ok, true} = Git.push(ws, "origin", "main:main")
      {bare_sha, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      assert String.trim(bare_sha) == sha
    end
  end

  describe "push/3 — timeout readback (a push that landed before the local kill is confirmed)" do
    # Timeout and readback are stubbed: tests the comparison decision,
    # not a real timeout or publication of accompanying refs.
    setup do
      on_exit(fn -> Application.delete_env(:lcars_fleet, :workflow_git_push_runner) end)
      :ok
    end

    test "push TIMES OUT but the remote target holds our SHA → {:ok, true} (confirmed by readback)" do
      sha = "abcdef0123456789abcdef0123456789abcdef01"

      Application.put_env(:lcars_fleet, :workflow_git_push_runner, fn args, _opts ->
        cond do
          "push" in args -> {:error, {:timeout, 100}}
          "rev-parse" in args -> {:ok, {"#{sha}\n", 0}}
          "ls-remote" in args -> {:ok, {"#{sha}\trefs/heads/main\n", 0}}
          true -> {:ok, {"", 0}}
        end
      end)

      assert {:ok, true} = Git.push("/ws", "origin", "HEAD:main")
    end

    test "push TIMES OUT and the remote holds a DIFFERENT SHA → the timeout stands" do
      Application.put_env(:lcars_fleet, :workflow_git_push_runner, fn args, _opts ->
        cond do
          "push" in args ->
            {:error, {:timeout, 100}}

          "rev-parse" in args ->
            {:ok, {"aaaaaaa0000000000000000000000000000000000\n", 0}}

          "ls-remote" in args ->
            {:ok, {"bbbbbbb1111111111111111111111111111111111\trefs/heads/main\n", 0}}

          true ->
            {:ok, {"", 0}}
        end
      end)

      assert {:error, {:git_push_timeout, _}} =
               Git.push("/ws", "origin", "HEAD:main")
    end

    test "push TIMES OUT and the remote has NO such ref → the timeout stands (push did not land)" do
      Application.put_env(:lcars_fleet, :workflow_git_push_runner, fn args, _opts ->
        cond do
          "push" in args -> {:error, {:timeout, 100}}
          "rev-parse" in args -> {:ok, {"aaaaaaa0000000000000000000000000000000000\n", 0}}
          "ls-remote" in args -> {:ok, {"", 0}}
          true -> {:ok, {"", 0}}
        end
      end)

      assert {:error, {:git_push_timeout, _}} =
               Git.push("/ws", "origin", "HEAD:main")
    end
  end

  describe "push/3 — F-PARALLEL-PR-CONFLICT (force on rewritten history)" do
    test "normal push rejected (non-fast-forward) → --force retry lands the rebased branch", %{
      tmp_dir: tmp
    } do
      bare = init_bare_repo(Path.join(tmp, "remote.git"))
      ws = init_workspace(Path.join(tmp, "ws"), remote_url: bare)
      commit_initial(ws, "C1")

      # initial push → the remote has C1.
      assert {:ok, true} = Git.push(ws, "origin", "HEAD:main")

      # rewrite history (amend = new sha diverging from the remote — like a resolution rebase).
      {_o, 0} = System.cmd("git", ["commit", "--amend", "-m", "C1-rebase"], cd: ws)
      {rewritten, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: ws)

      # Divergence retries with --force-with-lease against recorded remote-tracking state.
      assert {:ok, true} = Git.push(ws, "origin", "HEAD:main")

      {remote_head, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      assert String.trim(remote_head) == String.trim(rewritten)
    end

    # Git echoes tmp_dir, including test names. Avoid non-fast-forward, fetch first,
    # stale info and rejected where they must not trigger output classifiers.
    test "a racing producer advanced the remote: the leased force declines, the other commit is kept",
         %{
           tmp_dir: tmp
         } do
      bare = init_bare_repo(Path.join(tmp, "remote.git"))
      ws = init_workspace(Path.join(tmp, "ws"), remote_url: bare)
      commit_initial(ws, "C1")

      # our first push → remote at C1; ws records refs/remotes/origin/main = C1 (the lease basis).
      assert {:ok, true} = Git.push(ws, "origin", "HEAD:main")

      # a DUPLICATE/racing producer pushes a commit we never observed → the remote tip moves past C1
      # while OUR remote-tracking ref still says C1 (no fetch happened in our workspace).
      ws2 = Path.join(tmp, "ws2")
      {_o, 0} = System.cmd("git", ["clone", bare, ws2])
      {_o, 0} = System.cmd("git", ["config", "user.email", "c@x.y"], cd: ws2)
      {_o, 0} = System.cmd("git", ["config", "user.name", "racer"], cd: ws2)
      File.write!(Path.join(ws2, "other.txt"), "concurrent\n")
      {_o, 0} = System.cmd("git", ["add", "."], cd: ws2)
      {_o, 0} = System.cmd("git", ["commit", "-m", "CONCURRENT"], cd: ws2)
      {_o, 0} = System.cmd("git", ["push", "origin", "HEAD:main"], cd: ws2)
      {concurrent_sha, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)

      # our workspace rewrites history (amend, like a resolution rebase) → the re-push is non-ff.
      {_o, 0} = System.cmd("git", ["commit", "--amend", "-m", "C1-rebase"], cd: ws)

      # a BLIND --force (the old code) would obliterate the racer's commit. The LEASE expects our stale
      # C1, the remote is elsewhere → git declines → we surface :git_push_lease_stale, never clobber.
      assert {:error, {:git_push_lease_stale, "main", _out}} =
               Git.push(ws, "origin", "HEAD:main")

      # the racing producer's commit is intact on the remote (no silent data loss).
      {remote_head, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      assert String.trim(remote_head) == String.trim(concurrent_sha)
    end

    # Keep classifier substrings out of test names echoed in Git path diagnostics.
    test "MA-05: push refused by a server hook triggers NO brutal retry", %{tmp_dir: tmp} do
      bare = init_bare_repo(Path.join(tmp, "remote.git"))
      ws = init_workspace(Path.join(tmp, "ws"), remote_url: bare)
      commit_initial(ws, "C1")

      # Count hook invocations to distinguish one rejected attempt from a rejected retry;
      # unchanged remote state alone cannot distinguish them. The counter uses a simple
      # path because the generated shell redirects into it without quoting.
      counter =
        Fleet.TestEnv.tmp_path("ma05_hook_calls")

      File.rm(counter)
      hook = Path.join([bare, "hooks", "pre-receive"])

      File.write!(
        hook,
        "#!/bin/sh\necho x >> '#{counter}'\necho 'policy: pushes are blocked' >&2\nexit 1\n"
      )

      File.chmod!(hook, 0o755)
      on_exit(fn -> File.rm(counter) end)

      assert {:error, {:git_push_failed, rc, out}} =
               Git.push(ws, "origin", "HEAD:main")

      assert rc != 0
      assert out =~ "declined" or out =~ "rejected"

      # A retry would invoke the rejecting hook again.
      invocations = counter |> File.read!() |> String.split("\n", trim: true) |> length()

      assert invocations == 1,
             "hook invoked #{invocations}x — a --force retry was attempted (MA-05 regression)"

      # Complementary guard: the remote never received the ref.
      {_o, rev_rc} =
        System.cmd("git", ["rev-parse", "--verify", "main"], cd: bare, stderr_to_stdout: true)

      assert rev_rc != 0, "a declined hook must have pushed NOTHING to the remote"
    end
  end
end
