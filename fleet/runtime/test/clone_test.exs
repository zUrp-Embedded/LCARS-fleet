defmodule Fleet.ProjectBootstrap.CloneTest do
  # Doc-mount (invoked world): clones the code branch (workspace) + the doc branch (work/ops) into the pod.
  # REAL git fixture (no mock) — source repo with `main` + orphan branch `work/ops`.
  # async: git fixtures isolated by tmp_dir (git -C) — no application env mutated.
  use ExUnit.Case, async: true

  alias Fleet.ProjectBootstrap.Phase.Clone

  @moduletag :tmp_dir

  defp git(args, dir), do: System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)

  # Source repo: 1 commit on `main` (src.txt) + ORPHAN branch `work/ops` (BACKLOG.md).
  defp make_source_repo(dir) do
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir], stderr_to_stdout: true)
    {_, 0} = git(["config", "user.email", "t@lcars.local"], dir)
    {_, 0} = git(["config", "user.name", "test"], dir)
    File.write!(Path.join(dir, "src.txt"), "code-branch")
    {_, 0} = git(["add", "."], dir)
    {_, 0} = git(["commit", "-q", "-m", "code"], dir)

    {_, 0} = git(["checkout", "-q", "--orphan", "work/ops"], dir)
    {_, _} = git(["rm", "-rfq", "."], dir)
    File.write!(Path.join(dir, "BACKLOG.md"), "doc-branch")
    {_, 0} = git(["add", "."], dir)
    {_, 0} = git(["commit", "-q", "-m", "doc"], dir)
    {_, 0} = git(["checkout", "-q", "main"], dir)
    dir
  end

  defp cap(project) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      spec: %{"project" => project},
      metadata: %{"name" => "engineer"}
    }
  end

  test "NON-absolute pod_dir → {:error, {:unsafe_pod_dir}} (guard: never mkdir/rm_rf relative to cwd)" do
    on_exit(fn -> File.rm_rf("relative-pod-x") end)

    # repo_path nil → skip branch (mkdir workspace), no git: we isolate the GUARD, not the clone.
    profile = cap(%{})

    assert {:error, {:unsafe_pod_dir, "relative-pod-x"}} =
             Clone.clone_or_skip("relative-pod-x", profile, [])

    assert {:error, {:unsafe_pod_dir, "relative-pod-x"}} =
             Clone.clone_work_doc("relative-pod-x", profile)

    refute File.exists?("relative-pod-x"),
           "a relative pod_dir must create/erase NOTHING (guard before any I/O)"
  end

  test "clone code (workspace) + doc (work) side by side", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src"))
    pod_dir = Path.join(tmp, "pod-test-1")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/ops"})

    # code branch → <pod_dir>/workspace
    assert {:ok, ws, feature} = Clone.clone_or_skip(pod_dir, profile, [])
    assert ws == Path.join(pod_dir, "workspace")
    assert File.exists?(Path.join(ws, "src.txt"))
    assert feature =~ "feature/"

    # doc branch → <pod_dir>/work
    assert {:ok, doc} = Clone.clone_work_doc(pod_dir, profile)
    assert doc == Path.join(pod_dir, "work")
    assert File.exists?(Path.join(doc, "BACKLOG.md"))
    refute File.exists?(Path.join(doc, "src.txt"))
  end

  test "R1-07/08: malformed base_branch (`-inject`) → {:invalid_base_branch} BEFORE any git", %{
    tmp_dir: tmp
  } do
    pod_dir = Path.join(tmp, "pod-badref")
    File.mkdir_p!(pod_dir)
    # bogus repo_path: ref validation cuts BEFORE the clone, so we never reach it.
    profile = cap(%{"repo_path" => "/nonexistent/repo.git", "base_branch" => "-inject"})

    assert {:error, {:clone_failed, {:invalid_base_branch, "-inject"}}} =
             Clone.clone_or_skip(pod_dir, profile, [])
  end

  test "idempotence: residual workspace (dead predecessor pod) → cleaned + re-cloned, no clone_failed",
       %{tmp_dir: tmp} do
    # A timed-out/crashed pod leaves its workspace behind; the pod_id being DETERMINISTIC, the
    # re-dispatch lands on the same pod_dir → `git clone` refused (non-empty dest) → permanent wedge
    # of the issue. The fix cleans the residue before re-cloning.
    src = make_source_repo(Path.join(tmp, "src-idem"))
    pod_dir = Path.join(tmp, "pod-idem-1")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main"})

    # 1st clone OK (predecessor pod) + an uncommitted residue it would have left behind when dying.
    assert {:ok, ws, _} = Clone.clone_or_skip(pod_dir, profile, [])
    File.write!(Path.join(ws, "leftover.txt"), "junk from a dead pod")

    # re-dispatch on the SAME pod_dir: without rm_rf → {:error, {:clone_failed, _}}; with → clean re-clone.
    assert {:ok, ws2, feature2} = Clone.clone_or_skip(pod_dir, profile, [])
    assert ws2 == ws
    assert feature2 =~ "feature/"
    assert File.exists?(Path.join(ws2, "src.txt"))
    refute File.exists?(Path.join(ws2, "leftover.txt"))
  end

  test "#596 R1 — base_sha pins HEAD to the captured commit (not the remote tip)", %{tmp_dir: tmp} do
    src = Path.join(tmp, "src-pin")
    File.mkdir_p!(src)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
    {_, 0} = git(["config", "user.email", "t@lcars.local"], src)
    {_, 0} = git(["config", "user.name", "test"], src)
    File.write!(Path.join(src, "a.txt"), "1")
    {_, 0} = git(["add", "."], src)
    {_, 0} = git(["commit", "-q", "-m", "c1"], src)
    {c1, 0} = git(["rev-parse", "HEAD"], src)
    c1 = String.trim(c1)

    # C2 = current tip; the rail (out-of-pod ls-remote) that captured the base BEFORE C2 pinned C1.
    File.write!(Path.join(src, "b.txt"), "2")
    {_, 0} = git(["add", "."], src)
    {_, 0} = git(["commit", "-q", "-m", "c2"], src)

    pod_dir = Path.join(tmp, "pod-pin-1")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "base_sha" => c1})

    assert {:ok, ws, feature} = Clone.clone_or_skip(pod_dir, profile, [])
    {head, 0} = git(["rev-parse", "HEAD"], ws)

    # The pod's HEAD is guaranteed to START at C1 (pinned), not at tip C2 → base..HEAD = its commits only.
    assert String.trim(head) == c1
    assert feature =~ "feature/"
    assert File.exists?(Path.join(ws, "a.txt"))
    refute File.exists?(Path.join(ws, "b.txt"))
  end

  test "work_branch nil → skip (project without a doc branch)", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src2"))
    pod_dir = Path.join(tmp, "pod-test-2")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main"})

    assert {:ok, nil} = Clone.clone_work_doc(pod_dir, profile)
    refute File.exists?(Path.join(pod_dir, "work"))
  end

  test "work_branch declared but absent → fail-loud (I-CBC)", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src3"))
    pod_dir = Path.join(tmp, "pod-test-3")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/nope"})

    assert {:error, {:work_doc_clone_failed, {"work/nope", _code, _out}}} =
             Clone.clone_work_doc(pod_dir, profile)
  end

  # MA-22/F-BOOT-FM-03 — `rm_rf` parity: a residual `work/` (dead predecessor pod) must not
  # wedge the re-dispatch on "destination already exists".
  test "clone_work_doc idempotent: residual work/ → cleaned + re-cloned", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src-doc-idem"))
    pod_dir = Path.join(tmp, "pod-doc-idem")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/ops"})

    assert {:ok, doc} = Clone.clone_work_doc(pod_dir, profile)
    File.write!(Path.join(doc, "stale.txt"), "residue from a dead doc pod")

    # re-dispatch on the SAME pod_dir: without rm_rf → clone refuses (non-empty dest); with → clean re-clone.
    assert {:ok, ^doc} = Clone.clone_work_doc(pod_dir, profile)
    assert File.exists?(Path.join(doc, "BACKLOG.md"))
    refute File.exists?(Path.join(doc, "stale.txt"))
  end

  # ============================================================
  # MOVE-1/MA-22 — the clone is BOUNDED by construction: a HANGING git is killed within the deadline,
  # the pod does NOT stay zombie (the caller gets a typed error instead of freezing forever).
  # ============================================================
  test "hanging clone (mute git server) → killed within the timeout, typed error (no hang)",
       %{tmp_dir: tmp} do
    # Fake git server: a TCP socket that ACCEPTS the connection but NEVER answers. `git clone
    # git://127.0.0.1:PORT/x` connects, sends its request, and waits for an answer that never comes →
    # hang. Without the bound, `clone_or_skip` would freeze the calling process (in prod: the Pod
    # GenServer → zombie pod). With the bound (`:git_timeout_ms`), git is killed and we return
    # `{:clone_failed, {:git_timeout, ms}}` QUICKLY.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    # An acceptor that accepts then sleeps: the connection is established but stays mute.
    acceptor =
      spawn(fn ->
        case :gen_tcp.accept(listen, 10_000) do
          {:ok, sock} -> Process.sleep(:infinity) && sock
          _ -> :ok
        end
      end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    pod_dir = Path.join(tmp, "pod-hang")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => "git://127.0.0.1:#{port}/x", "base_branch" => "main"})

    t0 = System.monotonic_time(:millisecond)
    result = Clone.clone_or_skip(pod_dir, profile, git_timeout_ms: 400)
    elapsed = System.monotonic_time(:millisecond) - t0

    # TYPED error (the wrapper cut it), not a silent success nor an unhandled crash.
    assert {:error, {:clone_failed, {:git_timeout, 400}}} = result

    # We returned in ~400ms + margin, did NOT wait forever → the bound did kill the hanging git.
    assert elapsed < 5_000, "the clone hung for #{elapsed}ms — the bound did not cut"
  end

  # O5 (Brick 5) — `set_git_identity` test REMOVED with the function. The pod's git identity is no
  # longer set by a mutable `git config` in the workspace (falsifiable F-01) but injected as env at
  # launch (bwrap_launch.sh); the F-01 enforcement is the `DeliverableGate` at push (covered by
  # deliverable_gate_test.exs + executor_post_extract_test.exs git_native usurpation case).

  # ============================================================
  # SLOT-FREEZE — reset_in_place: COLD reset of a RESIDENT pipe's workspace for the next issue,
  # WITHOUT rm_rf (the ws is bind-mounted into the live bwrap sandbox — rm_rf would break the mount).
  # ============================================================
  test "reset_in_place — commit + untracked of the previous issue wiped, back to base_sha on feature/work, .git PRESERVED (no rm_rf)",
       %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src-reset"))
    {base, 0} = git(["rev-parse", "HEAD"], src)
    base = String.trim(base)
    pod_dir = Path.join(tmp, "pod-reset")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "base_sha" => base})

    # SPAWN: clone -> workspace on feature/work @ base.
    assert {:ok, ws, "feature/work"} = Clone.clone_or_skip(pod_dir, profile, [])

    # Sentinel INSIDE .git: an rm_rf+reclone would erase it; an IN-PLACE reset preserves it.
    sentinel = Path.join(ws, ".git/SENTINEL_INPLACE")
    File.write!(sentinel, "x")

    # The ENG works the previous issue: one COMMIT (woody) + one UNTRACKED file (buzz = the stacking
    # bug, uncommitted work lying around).
    {_, 0} = git(["config", "user.email", "e@lcars.local"], ws)
    {_, 0} = git(["config", "user.name", "eng"], ws)
    File.write!(Path.join(ws, "woody.sh"), "echo woody")
    {_, 0} = git(["add", "."], ws)
    {_, 0} = git(["commit", "-q", "-m", "previous issue"], ws)
    File.write!(Path.join(ws, "buzz.sh"), "echo buzz")

    # IN-PLACE RESET for the next issue (same base_sha): returns the SAME ws.
    assert {:ok, ^ws, "feature/work"} = Clone.reset_in_place(pod_dir, profile, [])

    # 1. back to base_sha (the "previous issue" commit is gone).
    {head, 0} = git(["rev-parse", "HEAD"], ws)
    assert String.trim(head) == base
    # 2. both the committed AND the untracked are cleaned (no more stacking possible).
    refute File.exists?(Path.join(ws, "woody.sh"))
    refute File.exists?(Path.join(ws, "buzz.sh"))
    # 3. on feature/work, clean.
    {branch, 0} = git(["rev-parse", "--abbrev-ref", "HEAD"], ws)
    assert String.trim(branch) == "feature/work"
    {status, 0} = git(["status", "--porcelain"], ws)
    assert String.trim(status) == ""

    # 4. IN-PLACE: the .git sentinel SURVIVED -> no rm_rf (the bind mount would be preserved for real).
    assert File.exists?(sentinel)
  end

  test "reset_in_place — base_sha absent → fail-loud {:reset_failed, :no_base_sha} (no blind reset)",
       %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src-nobase"))
    pod_dir = Path.join(tmp, "pod-nobase")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main"})

    assert {:ok, _ws, _} = Clone.clone_or_skip(pod_dir, profile, [])

    # Without base_sha the dispatcher pinned nothing = caller bug -> refuse rather than reset blindly.
    assert {:error, {:reset_failed, :no_base_sha}} = Clone.reset_in_place(pod_dir, profile, [])
  end

  test "reset_in_place — a REDUNDANT re-reprovision (caller timed out, the poll re-issues it) is a safe idempotent no-op",
       %{tmp_dir: tmp} do
    # `reprovision_pipe_workspace` is a bounded GenServer.call. If its deadline is exceeded (the
    # composed local git ops overrun only in a pathological case: a force-push erased the base AND a
    # slow fetch AND a huge untracked tree), the pod gen_statem still runs the reset to completion and
    # the poll re-issues reprovision on the next tick. Because the pod SERIALIZES its calls there is no
    # concurrent git (hence no index.lock race — the ops-serializer readback site had that race, this
    # one does not), so the only residual is a REDUNDANT reset. This proves that residual is harmless:
    # repeating the reset any number of times converges to the same clean state (at base, feature
    # branch, .git preserved) — the retry is a safe idempotent, never a corruption.
    src = make_source_repo(Path.join(tmp, "src-redundant"))
    {base, 0} = git(["rev-parse", "HEAD"], src)
    base = String.trim(base)
    pod_dir = Path.join(tmp, "pod-redundant")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "base_sha" => base})

    assert {:ok, ws, "feature/work"} = Clone.clone_or_skip(pod_dir, profile, [])
    sentinel = Path.join(ws, ".git/SENTINEL_INPLACE")
    File.write!(sentinel, "x")

    # First reset, then a leftover appears, then the redundant re-issues (twice) — as a stuck poll would.
    assert {:ok, ^ws, "feature/work"} = Clone.reset_in_place(pod_dir, profile, [])
    File.write!(Path.join(ws, "leftover.sh"), "echo leftover")
    assert {:ok, ^ws, "feature/work"} = Clone.reset_in_place(pod_dir, profile, [])
    assert {:ok, ^ws, "feature/work"} = Clone.reset_in_place(pod_dir, profile, [])

    # Converged: at base, clean, feature branch, .git preserved — no drift from the repeats.
    {head, 0} = git(["rev-parse", "HEAD"], ws)
    assert String.trim(head) == base
    refute File.exists?(Path.join(ws, "leftover.sh"))
    {branch, 0} = git(["rev-parse", "--abbrev-ref", "HEAD"], ws)
    assert String.trim(branch) == "feature/work"
    {status, 0} = git(["status", "--porcelain"], ws)
    assert String.trim(status) == ""
    assert File.exists?(sentinel)
  end
end
