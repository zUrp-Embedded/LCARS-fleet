defmodule Fleet.ProjectBootstrap.CloneTest do
  # Doc-mount (mundo invocado) : clone branche code (workspace) + branche doc (work/ops) dans le pod.
  # Fixture git RÉELLE (pas de mock) — repo source avec `main` + branche orpheline `work/ops`.
  use ExUnit.Case, async: false

  alias Fleet.ProjectBootstrap.Phase.Clone

  @moduletag :tmp_dir

  defp git(args, dir), do: System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)

  # Repo source : 1 commit sur `main` (src.txt) + branche ORPHELINE `work/ops` (BACKLOG.md).
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
    %Fleet.CapProfile{spec: %{"project" => project}, metadata: %{"name" => "engineer"}}
  end

  test "clone code (workspace) + doc (work) côte à côte", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src"))
    pod_dir = Path.join(tmp, "pod-test-1")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/ops"})

    # branche code → <pod_dir>/workspace
    assert {:ok, ws, feature} = Clone.clone_or_skip(pod_dir, profile, [])
    assert ws == Path.join(pod_dir, "workspace")
    assert File.exists?(Path.join(ws, "src.txt"))
    assert feature =~ "feature/"

    # branche doc → <pod_dir>/work
    assert {:ok, doc} = Clone.clone_work_doc(pod_dir, profile)
    assert doc == Path.join(pod_dir, "work")
    assert File.exists?(Path.join(doc, "BACKLOG.md"))
    refute File.exists?(Path.join(doc, "src.txt"))
  end

  test "#596 R1 — base_sha pinne HEAD sur le commit capturé (pas le tip remote)", %{tmp_dir: tmp} do
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
    # C2 = tip courant ; un Executor qui a ls-remote AVANT C2 a capturé C1.
    File.write!(Path.join(src, "b.txt"), "2")
    {_, 0} = git(["add", "."], src)
    {_, 0} = git(["commit", "-q", "-m", "c2"], src)

    pod_dir = Path.join(tmp, "pod-pin-1")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "base_sha" => c1})

    assert {:ok, ws, feature} = Clone.clone_or_skip(pod_dir, profile, [])
    {head, 0} = git(["rev-parse", "HEAD"], ws)

    # HEAD du pod COMMENCE garanti à C1 (épinglé), pas au tip C2 → base..HEAD = uniquement ses commits.
    assert String.trim(head) == c1
    assert feature =~ "feature/"
    assert File.exists?(Path.join(ws, "a.txt"))
    refute File.exists?(Path.join(ws, "b.txt"))
  end

  test "work_branch nil → skip (projet sans branche doc)", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src2"))
    pod_dir = Path.join(tmp, "pod-test-2")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main"})

    assert {:ok, nil} = Clone.clone_work_doc(pod_dir, profile)
    refute File.exists?(Path.join(pod_dir, "work"))
  end

  test "work_branch déclarée mais absente → fail-loud (I-CBC)", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "src3"))
    pod_dir = Path.join(tmp, "pod-test-3")
    File.mkdir_p!(pod_dir)
    profile = cap(%{"repo_path" => src, "base_branch" => "main", "work_branch" => "work/nope"})

    assert {:error, {:work_doc_clone_failed, {"work/nope", _code, _out}}} =
             Clone.clone_work_doc(pod_dir, profile)
  end

  # O5 (Brick 5) — test `set_git_identity` RETIRÉ avec la fonction. L'identité git du pod n'est plus
  # posée par un `git config` mutable dans le workspace (falsifiable F-01) mais injectée en env au
  # lancement (bwrap_launch.sh) ; l'enforcement F-01 est la gate `DeliverableGate` au push (couverte
  # par deliverable_gate_test.exs + executor_post_extract_test.exs cas git_native usurpation).
end
