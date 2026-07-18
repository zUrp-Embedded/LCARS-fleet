defmodule Fleet.Workflow.DeliverableGateTest do
  # Deliverable I-CBC gate (O5). REAL git fixture. Each consultant finding (F-01/F-02/F-03) must
  # be MECHANICALLY blocked: an invalid deliverable is unrepresentable at push time.
  # async: git fixtures isolated by tmp_dir (git -C) — no application env mutated.
  use ExUnit.Case, async: true

  alias Fleet.Workflow.DeliverableGate, as: Gate

  @moduletag :tmp_dir

  @role_emails ["engineer@lcars.local"]

  defp g(dir, args), do: System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)

  # Repo with a `base` commit (engineer identity) + one clean code commit. Returns {dir, base_sha}.
  defp setup_repo(dir) do
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir], stderr_to_stdout: true)
    {_, 0} = g(dir, ["config", "user.email", "engineer@lcars.local"])
    {_, 0} = g(dir, ["config", "user.name", "LCARS-engineer"])
    File.write!(Path.join(dir, "base.txt"), "base")
    {_, 0} = g(dir, ["add", "."])
    {_, 0} = g(dir, ["commit", "-q", "-m", "base"])
    {out, 0} = g(dir, ["rev-parse", "HEAD"])
    {dir, String.trim(out)}
  end

  defp commit_file(dir, name, content, msg) do
    File.write!(Path.join(dir, name), content)
    {_, 0} = g(dir, ["add", "."])
    {_, 0} = g(dir, ["commit", "-q", "-m", msg])
  end

  test "clean commit (role identity, zero secret) → verify OK", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "clean"))
    commit_file(dir, "feature.py", "def blink(): pass  # GPIO5", "feat: blink")

    assert {:ok, :verified} = Gate.verify(dir, base, @role_emails)
  end

  test "F-02 — OAuth token (JWT) in the diff → scan_secrets BLOCKS", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "leak-jwt"))
    # what `env > t.txt && git add` would do: a JWT in a file
    commit_file(dir, "t.txt", "TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload-stuff", "oops")

    assert {:error, {:secret_detected, "jwt_token", _}} = Gate.scan_secrets(dir, base)
    assert {:error, {:secret_detected, _, _}} = Gate.verify(dir, base, @role_emails)
  end

  test "F-02 — sk-ant- key in the diff → BLOCKS", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "leak-skant"))
    commit_file(dir, "cfg.txt", "key = sk-ant-api03-AbCdEf12345678", "cfg")

    assert {:error, {:secret_detected, "anthropic_key", _}} = Gate.scan_secrets(dir, base)
  end

  test "F-02 — blacklisted file (.credentials.json) → BLOCKED by name", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "leak-file"))
    commit_file(dir, ".credentials.json", "{}", "creds")

    assert {:error, {:secret_detected, "blacklisted_file", ".credentials.json"}} =
             Gate.scan_secrets(dir, base)
  end

  test "F-01 — commit with a forged identity → check_identity BLOCKS", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "fraud-id"))
    File.write!(Path.join(dir, "x.py"), "x = 1")
    {_, 0} = g(dir, ["add", "."])
    # the pod commits impersonating another role / a human
    {_, 0} =
      g(dir, [
        "-c",
        "user.email=architect@lcars.local",
        "-c",
        "user.name=evil",
        "commit",
        "-q",
        "-m",
        "fraud"
      ])

    assert {:error, {:bad_identity, ["architect@lcars.local"]}} =
             Gate.check_identity(dir, base, @role_emails)
  end

  test "F-03 — history rewrite (base no longer an ancestor) → check_base_ancestor BLOCKS",
       %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "rewrite"))
    # the pod rewrites the root commit → new SHA, original base unreachable from HEAD
    {_, 0} = g(dir, ["commit", "--amend", "-q", "-m", "rewritten-root", "--allow-empty"])

    assert {:error, {:base_not_ancestor, _}} = Gate.check_base_ancestor(dir, base)
  end

  test "F-03 / F-PARALLEL — base_not_ancestor message carries the base_sha (diagnostic, no mute tuple)",
       %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "diag"))
    {_, 0} = g(dir, ["commit", "--amend", "-q", "-m", "rewritten", "--allow-empty"])

    assert {:error, {:base_not_ancestor, msg}} = Gate.check_base_ancestor(dir, base)

    # a mute `{:base_not_ancestor, ""}` (empty merge-base output) is undiagnosable: the message
    # MUST name the offending base (12 hex) → the cause is visible in a single log line.
    assert msg =~ String.slice(base, 0, 12)
  end

  test "F-PARALLEL — rebase resolution: the gate ACCEPTS with base=main, REJECTS with base=feature_tip (clone/gate deconflation)",
       %{tmp_dir: tmp} do
    {dir, _c0} = setup_repo(Path.join(tmp, "rebase-resolve"))
    # the PRODUCER delivered on its feature branch (from C0).
    {_, 0} = g(dir, ["checkout", "-q", "-b", "feature"])
    commit_file(dir, "feature.py", "def blink(): pass  # GPIO5", "feat: blink")
    {ft, 0} = g(dir, ["rev-parse", "HEAD"])
    feature_tip = String.trim(ft)

    # a PARALLEL issue merged → `main` moves forward (C1). DIFFERENT file: the gate ONLY checks
    # ancestry + identity + secrets; RESOLVING the content conflict is the pod's job.
    {_, 0} = g(dir, ["checkout", "-q", "main"])
    commit_file(dir, "parallel.md", "# other issue", "feat: parallel issue")
    {m1, 0} = g(dir, ["rev-parse", "HEAD"])
    main_c1 = String.trim(m1)

    # the RESOLUTION eng rebases its feature onto `main` (C1) → HEAD = feat REPLAYED on C1 (fresh SHA).
    {_, 0} = g(dir, ["checkout", "-q", "feature"])
    {_, 0} = g(dir, ["rebase", "-q", "main"])

    # THE BUG (clone-base): `base_branch=head` pinned base_sha on the OLD feature tip, which the rebase
    # rewrote → no longer an ancestor of HEAD → `base_not_ancestor` (live PR#4, publish never reached).
    assert {:error, {:base_not_ancestor, msg}} = Gate.check_base_ancestor(dir, feature_tip)
    assert msg =~ String.slice(feature_tip, 0, 12)

    # THE FIX (gate_base_sha = main, the rebase target): HEAD descends from `main` → the gate ACCEPTS,
    # and the FULL verify passes (the replayed feat commit carries the engineer identity, zero secret
    # → publish + push).
    assert :ok = Gate.check_base_ancestor(dir, main_c1)
    assert {:ok, :verified} = Gate.verify(dir, main_c1, @role_emails)
  end

  test "empty range (no new commit) → identity OK (vacuity), scan OK", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "empty"))
    # base == HEAD, no commit since
    assert :ok = Gate.check_identity(dir, base, @role_emails)
    assert :ok = Gate.scan_secrets(dir, base)
    assert :ok = Gate.check_base_ancestor(dir, base)
  end

  # ============================================================
  # MA-09 — F-01 bypassed via BLANK email (anti-regression of the %x00 trap)
  # ============================================================

  test "MA-09 — commit with BLANK author/committer email → check_identity REJECTS {:bad_identity}",
       %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "blank-email"))
    File.write!(Path.join(dir, "x.py"), "x = 1")
    {_, 0} = g(dir, ["add", "."])

    # the pod commits with BLANK author AND committer emails (`env -i` / `user.email=""`) → a
    # `trim: true` split drops the blank lines → the empty email is never compared → gate `:ok`
    # (the MA-09 hole).
    {_, 0} =
      g(dir, [
        "-c",
        "user.email=",
        "-c",
        "user.name=ghost",
        "commit",
        "-q",
        "-m",
        "blank identity"
      ])

    assert {:error, {:bad_identity, bad}} = Gate.check_identity(dir, base, @role_emails)
    assert "<empty-email>" in bad
    # the FULL verify blocks too (the push never happens).
    assert {:error, {:bad_identity, _}} = Gate.verify(dir, base, @role_emails)
  end

  test "MA-09 (%x00 anti-regression) — a CLEAN multi-commit deliverable ALWAYS passes", %{
    tmp_dir: tmp
  } do
    {dir, base} = setup_repo(Path.join(tmp, "clean-multi"))
    commit_file(dir, "a.py", "a = 1", "feat: a")
    commit_file(dir, "b.py", "b = 2", "feat: b")
    commit_file(dir, "c.py", "c = 3", "feat: c")

    # NO terminal `[""]` false positive: all emails are engineer@lcars.local → :ok.
    assert :ok = Gate.check_identity(dir, base, @role_emails)
    assert {:ok, :verified} = Gate.verify(dir, base, @role_emails)
  end

  # ============================================================
  # MA-10 — PER-COMMIT secret scan (introduce-then-remove)
  # ============================================================

  test "MA-10 — secret INTRODUCED then REMOVED in the chain → scan_secrets BLOCKS (per-commit)",
       %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "introduce-remove"))

    # C1: introduces a JWT in a file.
    commit_file(
      dir,
      "leak.txt",
      "TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload-stuff",
      "wip"
    )

    # C2: removes the file → the NET diff base..HEAD is EMPTY (no trace), but the PUSH transfers C1.
    File.rm!(Path.join(dir, "leak.txt"))
    {_, 0} = g(dir, ["add", "-A"])
    {_, 0} = g(dir, ["commit", "-q", "-m", "cleanup"])

    # Sanity: the NET diff sees NOTHING (that is precisely the MA-10 hole).
    {net_diff, 0} = g(dir, ["diff", "#{base}..HEAD"])
    assert net_diff == "" or not (net_diff =~ "eyJ")

    # The PER-COMMIT scan, however, sees the secret in C1.
    assert {:error, {:secret_detected, "jwt_token", _}} = Gate.scan_secrets(dir, base)
  end

  test "MA-10 — secret file by NAME introduced then removed → BLOCKS per-commit", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "introduce-remove-file"))
    commit_file(dir, ".env", "SECRET=1", "wip env")
    File.rm!(Path.join(dir, ".env"))
    {_, 0} = g(dir, ["add", "-A"])
    {_, 0} = g(dir, ["commit", "-q", "-m", "remove env"])

    assert {:error, {:secret_detected, "blacklisted_file", ".env"}} = Gate.scan_secrets(dir, base)
  end

  # ============================================================
  # F-02 evil-merge — secret/file in the RESOLVED TREE of a merge (absent from both parents)
  # ============================================================

  # Builds an evil-merge: base → (feature: feat.txt) and (main: mainwork.txt) → no-ff merge whose
  # resolved TREE contains `extra_files` (present in NEITHER parent; base stays an ancestor;
  # author = legitimate engineer identity). Returns {dir, base_sha}.
  defp setup_evil_merge(dir, extra_files) do
    {dir, base} = setup_repo(dir)
    {_, 0} = g(dir, ["checkout", "-q", "-b", "feature"])
    commit_file(dir, "feat.txt", "feat", "feat")
    {_, 0} = g(dir, ["checkout", "-q", "main"])
    commit_file(dir, "mainwork.txt", "mainwork", "mainwork")
    {_, 0} = g(dir, ["checkout", "-q", "feature"])
    # no-ff merge of main into feature (the delivered HEAD is this merge).
    {_, 0} = g(dir, ["merge", "-q", "--no-ff", "-m", "merge main into feature", "main"])

    # EVIL: we inject into the merge tree files absent from BOTH parents, by amending the
    # merge commit (it keeps its two parents → still a merge; engineer author unchanged).
    Enum.each(extra_files, fn {name, content} ->
      File.write!(Path.join(dir, name), content)
    end)

    {_, 0} = g(dir, ["add", "-A"])
    {_, 0} = g(dir, ["commit", "-q", "--amend", "--no-edit"])
    {dir, base}
  end

  test "F-02 evil-merge — secret in the merge's resolved tree (NEITHER parent) → scan_secrets BLOCKS",
       %{tmp_dir: tmp} do
    # Distinct from MA-10 (LINEAR chain, each commit has its diff). Here the secret appears in the
    # diff of NO parent: it exists ONLY in the resolved tree of the MERGE commit. Without
    # `--diff-merges=first-parent`, `git log -p` emits no diff for a merge → the scan saw
    # nothing → the secret passed and got pushed. With it, the merge's delta vs its 1st parent is scanned.
    {dir, base} =
      setup_evil_merge(Path.join(tmp, "evil-merge-secret"), [
        {"f.txt", "key = sk-ant-api03-EvilMergeTree123"}
      ])

    # Sanity: f.txt exists in NEITHER of the merge's two parents (the secret lives ONLY in the
    # resolved tree) → `git show HEAD^N:f.txt` fails (rc 128, path unknown to the parent). That is
    # precisely what makes `git log -p` blind without `--diff-merges`.
    {_p1, rc1} = g(dir, ["show", "HEAD^1:f.txt"])
    {_p2, rc2} = g(dir, ["show", "HEAD^2:f.txt"])
    assert rc1 != 0, "f.txt should NOT exist in the 1st parent"
    assert rc2 != 0, "f.txt should NOT exist in the 2nd parent"

    assert {:error, {:secret_detected, "anthropic_key", _}} = Gate.scan_secrets(dir, base)
    assert {:error, {:secret_detected, _, _}} = Gate.verify(dir, base, @role_emails)
  end

  test "F-02 evil-merge — blacklisted file (id_rsa) in the resolved tree → BLOCKED by name",
       %{tmp_dir: tmp} do
    {dir, base} =
      setup_evil_merge(Path.join(tmp, "evil-merge-file"), [{"id_rsa", "-----PRIV-----"}])

    assert {:error, {:secret_detected, "blacklisted_file", "id_rsa"}} =
             Gate.scan_secrets(dir, base)
  end

  test "CLEAN evil-merge (resolved tree without secret) → verify OK (no false positive on merges)",
       %{tmp_dir: tmp} do
    # `--diff-merges=first-parent` must not fail a LEGITIMATE merge: a merge whose resolved tree
    # contains no secret and no forbidden file, engineer identity, base an ancestor → :ok.
    {dir, base} =
      setup_evil_merge(Path.join(tmp, "clean-merge"), [{"notes.txt", "clean merge summary"}])

    assert {:ok, :verified} = Gate.verify(dir, base, @role_emails)
  end

  # ============================================================
  # MA-24 — check_base_ancestor: TYPED rc (rc1 not-an-ancestor / rc128 git_error / rc124 timeout)
  # ============================================================

  test "MA-24 — BOGUS base_sha (rc128) → {:git_error}, NOT {:base_not_ancestor}", %{tmp_dir: tmp} do
    {dir, _base} = setup_repo(Path.join(tmp, "bogus-base"))
    commit_file(dir, "f.py", "x = 1", "feat")

    # a sha that does not exist → `merge-base --is-ancestor` rc128 (invalid object), NOT rc1.
    bogus = "0000000000000000000000000000000000000000"
    assert {:error, {:git_error, _}} = Gate.check_base_ancestor(dir, bogus)
  end

  test "MA-24 — real not-an-ancestor base (rc1) stays {:base_not_ancestor}", %{tmp_dir: tmp} do
    {dir, base} = setup_repo(Path.join(tmp, "real-not-ancestor"))
    {_, 0} = g(dir, ["commit", "--amend", "-q", "-m", "rewritten", "--allow-empty"])

    assert {:error, {:base_not_ancestor, msg}} = Gate.check_base_ancestor(dir, base)
    assert msg =~ String.slice(base, 0, 12)
  end
end
