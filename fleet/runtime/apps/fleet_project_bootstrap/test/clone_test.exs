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

  test "set_git_identity : LCARS-<role> si injects.gitconfig ; no-op sinon", %{tmp_dir: tmp} do
    src = make_source_repo(Path.join(tmp, "srcg"))
    ws = Path.join(tmp, "ws-on")

    {_, 0} =
      System.cmd("git", ["clone", "-q", "--branch", "main", src, ws], stderr_to_stdout: true)

    p_on = %Fleet.CapProfile{
      metadata: %{"name" => "engineer"},
      spec: %{"injects" => %{"gitconfig" => true}}
    }

    assert :ok = Clone.set_git_identity(ws, p_on)
    {name, 0} = System.cmd("git", ["-C", ws, "config", "user.name"], stderr_to_stdout: true)
    assert String.trim(name) == "LCARS-engineer"
    {email, 0} = System.cmd("git", ["-C", ws, "config", "user.email"], stderr_to_stdout: true)
    assert String.trim(email) == "engineer@lcars.local"

    # injects.gitconfig absent → no-op (pas d'identité LCARS posée localement)
    ws2 = Path.join(tmp, "ws-off")

    {_, 0} =
      System.cmd("git", ["clone", "-q", "--branch", "main", src, ws2], stderr_to_stdout: true)

    p_off = %Fleet.CapProfile{metadata: %{"name" => "qualifier"}, spec: %{"injects" => %{}}}
    assert :ok = Clone.set_git_identity(ws2, p_off)

    {out, code} =
      System.cmd("git", ["-C", ws2, "config", "--local", "user.name"], stderr_to_stdout: true)

    assert code != 0 or String.trim(out) != "LCARS-qualifier"
  end
end
