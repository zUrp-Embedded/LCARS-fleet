defmodule Fleet.Pipeline.WorkspaceProvisionerTest do
  @moduledoc """
  Face 2 brique 2.4 — tests purs du provisioner workspace (clone + checkout
  branche). Pas de pod, pas de claude. Utilise un bare repo local comme
  source de clone (file:///path/to/bare.git → git accepte).
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.Pipeline.WorkspaceProvisioner

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_pipeline, :workspaces_root, Path.join(tmp_dir, "ws-root"))

    on_exit(fn ->
      Application.delete_env(:fleet_pipeline, :workspaces_root)
    end)

    :ok
  end

  # Crée un bare repo + un commit initial sur `main` (rendu accessible via
  # un clone éphémère puis push).
  defp seed_remote(tmp_dir, name) do
    bare = Path.join(tmp_dir, "#{name}.git")
    File.mkdir_p!(bare)
    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])

    seeder = Path.join(tmp_dir, "#{name}-seeder")
    File.mkdir_p!(seeder)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", seeder])
    {_, 0} = System.cmd("git", ["config", "user.name", "seeder"], cd: seeder)
    {_, 0} = System.cmd("git", ["config", "user.email", "s@e"], cd: seeder)
    File.write!(Path.join(seeder, "README.md"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: seeder)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: seeder)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", bare], cd: seeder)
    {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: seeder)

    bare
  end

  # ============================================================
  # No-op (git_spec nil) + path helper
  # ============================================================

  test "provision_for_stage(_, _, nil) → {:ok, nil} no-op" do
    assert {:ok, nil} = WorkspaceProvisioner.provision_for_stage("p1", "publish", nil)
  end

  test "workspace_dir_for/2 — convention <:workspaces_root>/<pipeline_id>/<stage>/workspace" do
    root = Application.get_env(:fleet_pipeline, :workspaces_root)

    assert WorkspaceProvisioner.workspace_dir_for("pipe-1", "publish") ==
             Path.join([root, "pipe-1", "publish", "workspace"])
  end

  # ============================================================
  # Clone + checkout
  # ============================================================

  test "git_spec OK → clone bare repo + checkout main", %{tmp_dir: tmp_dir} do
    bare = seed_remote(tmp_dir, "repo")
    git_spec = %{"repo_url" => bare, "branch" => "main"}

    assert {:ok, ws} = WorkspaceProvisioner.provision_for_stage("p1", "publish", git_spec)

    assert File.dir?(ws)
    assert File.dir?(Path.join(ws, ".git"))
    assert File.exists?(Path.join(ws, "README.md"))

    {branch, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: ws)
    assert String.trim(branch) == "main"
  end

  test "branche absente du remote → checkout -b (créée localement depuis HEAD)",
       %{tmp_dir: tmp_dir} do
    bare = seed_remote(tmp_dir, "repo2")
    git_spec = %{"repo_url" => bare, "branch" => "feature/new"}

    assert {:ok, ws} = WorkspaceProvisioner.provision_for_stage("p2", "publish", git_spec)

    {branch, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: ws)
    assert String.trim(branch) == "feature/new"
  end

  test "idempotence : re-provision sur workspace existant → checkout réussit, pas de re-clone",
       %{tmp_dir: tmp_dir} do
    bare = seed_remote(tmp_dir, "repo3")
    git_spec = %{"repo_url" => bare, "branch" => "main"}

    {:ok, ws1} = WorkspaceProvisioner.provision_for_stage("p3", "publish", git_spec)
    # Modifie le workspace pour détecter un éventuel re-clone destructif.
    File.write!(Path.join(ws1, "marker.txt"), "preserved\n")

    {:ok, ws2} = WorkspaceProvisioner.provision_for_stage("p3", "publish", git_spec)
    assert ws1 == ws2
    assert File.exists?(Path.join(ws2, "marker.txt"))
  end

  # ============================================================
  # Erreurs
  # ============================================================

  test "git_spec sans repo_url → :missing_key" do
    assert {:error, {:missing_key, "repo_url"}} =
             WorkspaceProvisioner.provision_for_stage("p4", "publish", %{"branch" => "main"})
  end

  test "git_spec sans branch → :missing_key" do
    assert {:error, {:missing_key, "branch"}} =
             WorkspaceProvisioner.provision_for_stage("p5", "publish", %{
               "repo_url" => "/tmp/nope"
             })
  end

  test "repo_url invalide → :clone_failed", %{tmp_dir: tmp_dir} do
    git_spec = %{"repo_url" => Path.join(tmp_dir, "nope.git"), "branch" => "main"}

    assert {:error, {:clone_failed, rc, out}} =
             WorkspaceProvisioner.provision_for_stage("p6", "publish", git_spec)

    assert rc != 0
    assert is_binary(out)
  end
end
