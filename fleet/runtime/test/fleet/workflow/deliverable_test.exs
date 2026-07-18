defmodule Fleet.Workflow.DeliverableTest do
  # Unified O5 publication — REAL git fixture (workspace + bare remote). Both modes (payload /
  # git_native) go through the SAME gate + the SAME push; only the CONTENT time differs. An invalid
  # deliverable (secret, forged identity, rewritten history) is unrepresentable at push time.
  # async: git fixtures isolated by tmp_dir (git -C, local remotes) — no application env mutated.
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Deliverable

  @moduletag :tmp_dir

  defp g(dir, args), do: System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)

  # Bare remote + cloned workspace, with a base commit (engineer identity). Returns {ws, bare, base}.
  defp setup_ws(tmp, name) do
    bare = Path.join(tmp, "#{name}.git")
    File.mkdir_p!(bare)
    {_, 0} = System.cmd("git", ["init", "--bare", "-b", "main", bare], stderr_to_stdout: true)

    ws = Path.join(tmp, "#{name}-ws")
    File.mkdir_p!(ws)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", ws], stderr_to_stdout: true)
    {_, 0} = g(ws, ["config", "user.email", "engineer@lcars.local"])
    {_, 0} = g(ws, ["config", "user.name", "LCARS-engineer"])
    {_, 0} = g(ws, ["remote", "add", "origin", bare])
    File.write!(Path.join(ws, "base.txt"), "base")
    {_, 0} = g(ws, ["add", "."])
    {_, 0} = g(ws, ["commit", "-q", "-m", "base"])
    {_, 0} = g(ws, ["push", "-q", "origin", "main"])
    {out, 0} = g(ws, ["rev-parse", "HEAD"])
    {ws, bare, String.trim(out)}
  end

  # System-side identity of the payload commit (D-04: author=role, committer=system).
  defp payload_identity do
    %{
      author_name: "LCARS-engineer",
      author_email: "engineer@lcars.local",
      committer_name: "Fixture Committer",
      committer_email: "committer@fixture.test"
    }
  end

  defp payload_allowed, do: ["engineer@lcars.local", "committer@fixture.test"]

  describe "mode :payload" do
    test "writes + commits (system) + gate OK + push onto the system-chosen branch (F-04)",
         %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "payload-ok")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/engineer/m-42",
        files: [%{"path" => "src/blink.py", "content" => "def blink(): pass  # GPIO5\n"}],
        identity: payload_identity(),
        message: "feat: blink"
      }

      assert {:ok, %{commit_sha: <<_::binary-size(40)>> = sha, pushed?: true, mode: :payload}} =
               Deliverable.publish(opts)

      # F-04: the pushed ref is the one chosen by the system, not "main".
      {pushed, 0} = g(bare, ["rev-parse", "deliverables/engineer/m-42"])
      assert String.trim(pushed) == sha
      # base/main on the remote did not move.
      {main, 0} = g(bare, ["rev-parse", "main"])
      assert String.trim(main) == base

      # D-04: author=role, committer=system.
      {who, 0} = g(ws, ["log", "-1", "--format=%ae|%ce"])
      assert String.trim(who) == "engineer@lcars.local|committer@fixture.test"
    end

    test "R2-07/10 : a MISTYPED required field → {:error, {:bad_opt, _}} (types validated, not just presence)" do
      # the type-check cuts BEFORE the git ops → no real ws needed
      base = %{
        mode: :payload,
        workspace: "/tmp/ws",
        base_sha: "abc",
        allowed_emails: ["e@x"],
        files: [],
        identity: %{},
        message: "m"
      }

      assert {:error, {:bad_opt, {:workspace, _}}} = Deliverable.publish(%{base | workspace: 42})
      assert {:error, {:bad_opt, {:base_sha, _}}} = Deliverable.publish(%{base | base_sha: nil})

      assert {:error, {:bad_opt, {:allowed_emails, _}}} =
               Deliverable.publish(%{base | allowed_emails: "e@x"})

      assert {:error, {:bad_opt, {:allowed_emails, _}}} =
               Deliverable.publish(%{base | allowed_emails: [42]})
    end

    test "secret in the payload → gate BLOCKS, NO push", %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "payload-secret")
      {before, 0} = g(bare, ["rev-parse", "main"])

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [%{"path" => "leak.txt", "content" => "TOKEN=sk-ant-api03-LEAKED123456\n"}],
        identity: payload_identity(),
        message: "oops"
      }

      assert {:error, {:secret_detected, "anthropic_key", _}} = Deliverable.publish(opts)

      # The local commit happened (time 1) but the push did NOT happen (time 3 never reached).
      {after_push, 0} = g(bare, ["rev-parse", "main"])
      assert before == after_push
      assert {_, 1} = g(bare, ["rev-parse", "--verify", "-q", "deliverables/x"])
    end

    test "payload without files → :no_files_in_payload", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-empty")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [],
        identity: payload_identity(),
        message: "nothing"
      }

      assert {:error, :no_files_in_payload} = Deliverable.publish(opts)
    end

    test "F-07 — .git/hooks/ planted by the pod do NOT execute world-side (commit+push)",
         %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "payload-hooks")
      sentinel = Path.join(tmp, "pwned")
      hooks = Path.join([ws, ".git", "hooks"])
      File.mkdir_p!(hooks)
      # The pod (adversary) plants pre-commit AND pre-push hooks that would run code world-side.
      for h <- ["pre-commit", "pre-push"] do
        p = Path.join(hooks, h)
        File.write!(p, "#!/bin/sh\ntouch #{sentinel}\n")
        File.chmod!(p, 0o755)
      end

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [%{"path" => "a.txt", "content" => "a\n"}],
        identity: payload_identity(),
        message: "feat: a"
      }

      assert {:ok, %{pushed?: true}} = Deliverable.publish(opts)
      # core.hooksPath=/dev/null on the system-side ops → no hook executed.
      refute File.exists?(sentinel)
      # The deliverable is still properly pushed (the fix does not break publication).
      {_pushed, 0} = g(bare, ["rev-parse", "deliverables/x"])
    end

    test "path traversal in the payload → BLOCKS before any write", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-traversal")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [%{"path" => "../escape.txt", "content" => "x"}],
        identity: payload_identity(),
        message: "evil"
      }

      assert {:error, {:path_traversal, "../escape.txt"}} = Deliverable.publish(opts)
    end

    test "WI-1 — payload `.gitattributes filter=` + armed clean filter → REFUSED, the filter does NOT run",
         %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-clean-filter")

      # RCE vector: a `clean` filter with an arbitrary command is armed in the repo's `.git/config`. The
      # payload tries to add the `.gitattributes` that MAPS `*.txt` to that filter. If the deliverable is
      # not refused, the system-side `git add` that follows EXECUTES the filter command world-side (outside bwrap).
      sentinel = Path.join(tmp, "clean_filter_ran")
      File.rm(sentinel)

      {_, 0} =
        g(ws, ["config", "filter.pwn.clean", "sh -c 'touch #{sentinel}; cat'"])

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [
          %{"path" => ".gitattributes", "content" => "*.txt filter=pwn\n"},
          %{"path" => "x.txt", "content" => "hello\n"}
        ],
        identity: payload_identity(),
        message: "evil filter"
      }

      # CONTENT stage (load-bearing): the `.gitattributes` arming `filter=` is refused BEFORE any write.
      assert {:error, {:dangerous_gitattributes, ".gitattributes"}} = Deliverable.publish(opts)

      # The filter NEVER ran (no system-side git add took place).
      refute File.exists?(sentinel)
      # Nothing was written (2-pass validation: validate everything before writing anything).
      refute File.exists?(Path.join(ws, ".gitattributes"))
      refute File.exists?(Path.join(ws, "x.txt"))
    end

    test "WI-1 — payload writing under `.git/` (e.g. `.git/config`) → REFUSED before any write",
         %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-dotgit")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [
          %{
            "path" => ".git/config",
            "content" => "[filter \"pwn\"]\n\tclean = touch /tmp/pwned\n"
          }
        ],
        identity: payload_identity(),
        message: "evil config"
      }

      assert {:error, {:dotgit_path, ".git/config"}} = Deliverable.publish(opts)
    end

    test "WI-1 — a BENIGN `.gitattributes` (no filter=/diff=) stays allowed",
         %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "payload-benign-attrs")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/benign",
        # `text`/`eol` execute no external command → not blocked (no false positive).
        files: [%{"path" => ".gitattributes", "content" => "*.txt text eol=lf\n"}],
        identity: payload_identity(),
        message: "benign attrs"
      }

      assert {:ok, %{pushed?: true}} = Deliverable.publish(opts)
      {_pushed, 0} = g(bare, ["rev-parse", "deliverables/benign"])
    end

    test "F081 — checked-in symlink in the workspace → BLOCKS (no escape via File.write)",
         %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "payload-symlink")
      # Vector: a cloned repo with a trap symlink `out` -> outside the workspace. The lexical check
      # (Path.expand) passes; File.write WOULD follow the link → escape. Must be blocked.
      escape = Path.join(tmp, "escape-target")
      File.mkdir_p!(escape)
      File.ln_s!(escape, Path.join(ws, "out"))

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "deliverables/x",
        files: [%{"path" => "out/escape.txt", "content" => "x"}],
        identity: payload_identity(),
        message: "evil"
      }

      assert {:error, {:symlink_escape, "out/escape.txt"}} = Deliverable.publish(opts)
      refute File.exists?(Path.join(escape, "escape.txt"))
    end
  end

  describe "mode :git_native" do
    test "the agent committed → gate OK + push (system rewrites nothing)", %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "native-ok")
      # The pod commits by itself (role identity, injected immutable in prod — simulated here).
      File.write!(Path.join(ws, "feature.py"), "x = 1\n")
      {_, 0} = g(ws, ["add", "."])
      {_, 0} = g(ws, ["commit", "-q", "-m", "feat: agent work"])

      opts = %{
        mode: :git_native,
        workspace: ws,
        base_sha: base,
        allowed_emails: ["engineer@lcars.local"],
        remote: "origin",
        target_branch: "deliverables/engineer/native"
      }

      assert {:ok, %{pushed?: true, mode: :git_native, commit_sha: sha}} =
               Deliverable.publish(opts)

      {pushed, 0} = g(bare, ["rev-parse", "deliverables/engineer/native"])
      assert String.trim(pushed) == sha
    end

    test "no commit produced (HEAD == base) → :no_deliverable_commit", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "native-empty")

      opts = %{
        mode: :git_native,
        workspace: ws,
        base_sha: base,
        allowed_emails: ["engineer@lcars.local"],
        remote: "origin",
        target_branch: "deliverables/x"
      }

      assert {:error, :no_deliverable_commit} = Deliverable.publish(opts)
    end

    test "identity forged by the agent → gate BLOCKS, NO push", %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "native-fraud")
      {before, 0} = g(bare, ["rev-parse", "main"])
      File.write!(Path.join(ws, "x.py"), "x = 1\n")
      {_, 0} = g(ws, ["add", "."])

      {_, 0} =
        g(ws, [
          "-c",
          "user.email=architect@lcars.local",
          "-c",
          "user.name=evil",
          "commit",
          "-q",
          "-m",
          "fraud"
        ])

      opts = %{
        mode: :git_native,
        workspace: ws,
        base_sha: base,
        allowed_emails: ["engineer@lcars.local"],
        remote: "origin",
        target_branch: "deliverables/x"
      }

      assert {:error, {:bad_identity, ["architect@lcars.local"]}} = Deliverable.publish(opts)
      {after_push, 0} = g(bare, ["rev-parse", "main"])
      assert before == after_push
    end
  end

  describe "validation" do
    test "unknown mode → :invalid_mode", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "bad-mode")

      assert {:error, {:invalid_mode, :wat}} =
               Deliverable.publish(%{
                 mode: :wat,
                 workspace: ws,
                 base_sha: base,
                 allowed_emails: []
               })
    end

    test "malformed target_branch (F-04 kept) → :invalid_ref, no write", %{tmp_dir: tmp} do
      {ws, _bare, base} = setup_ws(tmp, "bad-ref")

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        remote: "origin",
        target_branch: "../evil",
        files: [%{"path" => "a.txt", "content" => "a\n"}],
        identity: payload_identity(),
        message: "x"
      }

      assert {:error, {:invalid_ref, "../evil"}} = Deliverable.publish(opts)
      # validation BEFORE time 1: nothing was written/committed.
      {st, 0} = g(ws, ["status", "--porcelain"])
      assert String.trim(st) == ""
    end

    test "push? false → local commit, no push, target_branch optional", %{tmp_dir: tmp} do
      {ws, bare, base} = setup_ws(tmp, "no-push")
      {before, 0} = g(bare, ["rev-parse", "main"])

      opts = %{
        mode: :payload,
        workspace: ws,
        base_sha: base,
        allowed_emails: payload_allowed(),
        push?: false,
        files: [%{"path" => "a.txt", "content" => "a\n"}],
        identity: payload_identity(),
        message: "local only"
      }

      assert {:ok, %{pushed?: false, mode: :payload}} = Deliverable.publish(opts)
      {after_push, 0} = g(bare, ["rev-parse", "main"])
      assert before == after_push
    end
  end
end
