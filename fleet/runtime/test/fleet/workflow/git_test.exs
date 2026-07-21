defmodule Fleet.GitTest do
  use ExUnit.Case, async: true

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

    # Default local config — otherwise git refuses commits without user.*, and some
    # hooks too. Our code forces GIT_AUTHOR_*/GIT_COMMITTER_* via env, but git reads
    # user.name/user.email for the commit even when the env is set on some versions;
    # we set them to neutralize that.
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

      assert {:ok, <<_::binary-size(40)>>} = Fleet.Workflow.Git.commit(valid_opts(ws))

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
      assert {:ok, _} = Fleet.Workflow.Git.commit(opts)

      {staged_files, 0} = System.cmd("git", ["show", "--name-only", "--format=", "HEAD"], cd: ws)
      assert String.trim(staged_files) == "docs/X.md"
    end

    test "fail-closed: missing workspace", %{tmp_dir: tmp} do
      assert {:error, :workspace_missing} =
               Fleet.Workflow.Git.commit(valid_opts(Path.join(tmp, "nope")))
    end

    test "fail-closed: workspace is not a git repo", %{tmp_dir: tmp} do
      ws = Path.join(tmp, "not-git")
      File.mkdir_p!(ws)

      assert {:error, :not_a_git_workspace} = Fleet.Workflow.Git.commit(valid_opts(ws))
    end

    test "fail-closed: nothing to commit → :nothing_to_commit", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-empty"))
      commit_initial(ws)
      # NO modification after the seed → git commit refuses.
      assert {:error, :nothing_to_commit} = Fleet.Workflow.Git.commit(valid_opts(ws))
    end

    test "fail-closed: missing opts", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-bad"))
      commit_initial(ws)

      opts = valid_opts(ws) |> Map.delete(:author_email) |> Map.delete(:message)
      assert {:error, {:missing_opts, missing}} = Fleet.Workflow.Git.commit(opts)
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

      # Without `--`, `git add --all` would stage sneaky.txt → {:ok}. With `--`, "--all" is a literal
      # pathspec (absent) → failure: the option-injection is neutralized (nothing mass-staged).
      assert {:error, _} = Fleet.Workflow.Git.commit(opts)
    end

    test "F-014: invalid add_paths (empty / non-binary / empty element) → :invalid_add_paths",
         %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f014b"))
      commit_initial(ws)
      File.write!(Path.join(ws, "x.txt"), "x\n")

      for bad <- [[], [123], ["", "ok"], "not-a-list"] do
        opts = Map.put(valid_opts(ws), :add_paths, bad)

        assert {:error, :invalid_add_paths} = Fleet.Workflow.Git.commit(opts),
               "add_paths #{inspect(bad)}"
      end
    end

    test "F-046: leading-`-` push remote rejected fail-closed (`-c`, `--receive-pack=`, `--exec=`)",
         %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f046"))

      for bad <- ["-c", "--receive-pack=touch /tmp/pwn", "--exec=x"] do
        assert {:error, {:invalid_remote, ^bad}} = Fleet.Workflow.Git.push(ws, bad, "HEAD:main"),
               "remote #{inspect(bad)}"
      end
    end

    test "F-046: leading-`-` push refspec rejected", %{tmp_dir: tmp} do
      ws = init_workspace(Path.join(tmp, "ws-f046b"))

      assert {:error, {:invalid_refspec, "--force"}} =
               Fleet.Workflow.Git.push(ws, "origin", "--force")
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

      assert {:ok, sha} = Fleet.Workflow.Git.commit(valid_opts(ws))
      # commit/1 does NOT touch the remote (content/publication separation)…
      {bare_head, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      refute String.trim(bare_head) == sha

      # …push/3 is what publishes.
      assert {:ok, true} = Fleet.Workflow.Git.push(ws, "origin", "main:main")
      {bare_sha, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      assert String.trim(bare_sha) == sha
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
      assert {:ok, true} = Fleet.Workflow.Git.push(ws, "origin", "HEAD:main")

      # rewrite history (amend = new sha diverging from the remote — like a resolution rebase).
      {_o, 0} = System.cmd("git", ["commit", "--amend", "-m", "C1-rebase"], cd: ws)
      {rewritten, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: ws)

      # a normal push would be "non-fast-forward" → do_push retries `--force` → lands (without it,
      # the resolution rebase NEVER lands and the PR stays in conflict, the live PR#4 bug).
      assert {:ok, true} = Fleet.Workflow.Git.push(ws, "origin", "HEAD:main")

      {remote_head, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      assert String.trim(remote_head) == String.trim(rewritten)
    end

    # NB naming (as above): the tmp_dir path embeds the test name into git's output; the name must avoid
    # every substring the classifiers key on — `non_fast_forward?` (non-fast-forward / fetch first) AND
    # `lease_stale?` (stale info / rejected) — hence "declines" / "kept", not "rejected"/"stale".
    test "a racing producer advanced the remote: the leased force declines, the other commit is kept",
         %{
           tmp_dir: tmp
         } do
      bare = init_bare_repo(Path.join(tmp, "remote.git"))
      ws = init_workspace(Path.join(tmp, "ws"), remote_url: bare)
      commit_initial(ws, "C1")

      # our first push → remote at C1; ws records refs/remotes/origin/main = C1 (the lease basis).
      assert {:ok, true} = Fleet.Workflow.Git.push(ws, "origin", "HEAD:main")

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
               Fleet.Workflow.Git.push(ws, "origin", "HEAD:main")

      # the racing producer's commit is intact on the remote (no silent data loss).
      {remote_head, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
      assert String.trim(remote_head) == String.trim(concurrent_sha)
    end

    # NB naming: the ExUnit tmp_dir is derived from the test name; git embeds that path in its error
    # output. The name must NOT contain the substrings classified by `non_fast_forward?` (otherwise the
    # path pollutes `out` and makes a false positive). Hence a deliberately neutral wording.
    test "MA-05: push refused by a server hook triggers NO brutal retry", %{tmp_dir: tmp} do
      bare = init_bare_repo(Path.join(tmp, "remote.git"))
      ws = init_workspace(Path.join(tmp, "ws"), remote_url: bare)
      commit_initial(ws, "C1")

      # pre-receive hook that REFUSES every push → git emits "[remote rejected] … pre-receive hook
      # declined" (the substring `rejected` WITHOUT `non-fast-forward`). Without MA-05,
      # `non_fast_forward?` matched `rejected` → wrongful `--force` retry (forced rewrite over a
      # server-side guard).
      #
      # DISCRIMINANT: the hook COUNTS its invocations (1 `x` line/call in a witness file). A single
      # normal push → 1 invocation. If the fix regresses and attempts `--force`, git re-runs the push
      # (force does NOT bypass a pre-receive) → 2 invocations. The COUNT proves the absence of a
      # force retry, where observing the remote could not (force-declined fails like push-declined).
      # The counter lives in a path WITHOUT special characters: the ExUnit tmp_dir embeds the test
      # name (parentheses, `→`, `≠`) which, interpolated unquoted into the hook's `sh`, would break
      # the redirection.
      counter =
        Path.join(System.tmp_dir!(), "ma05_hook_calls_#{System.unique_integer([:positive])}")

      File.rm(counter)
      hook = Path.join([bare, "hooks", "pre-receive"])

      File.write!(
        hook,
        "#!/bin/sh\necho x >> '#{counter}'\necho 'policy: pushes are blocked' >&2\nexit 1\n"
      )

      File.chmod!(hook, 0o755)
      on_exit(fn -> File.rm(counter) end)

      assert {:error, {:git_push_failed, rc, out}} =
               Fleet.Workflow.Git.push(ws, "origin", "HEAD:main")

      assert rc != 0
      assert out =~ "declined" or out =~ "rejected"

      # THE test: the hook was invoked only ONCE → no `--force` retry (which would have re-triggered it).
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
