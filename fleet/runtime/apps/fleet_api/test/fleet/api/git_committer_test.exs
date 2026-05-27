defmodule Fleet.API.GitCommitterTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.API.GitCommitter

  setup %{tmp_dir: tmp_dir} do
    System.cmd("git", ["init", "--quiet"], cd: tmp_dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

    System.cmd("git", ["commit", "--allow-empty", "-m", "initial"],
      cd: tmp_dir,
      stderr_to_stdout: true
    )

    Application.put_env(:fleet_api, :git_repo_path, tmp_dir)

    on_exit(fn ->
      Application.delete_env(:fleet_api, :git_repo_path)
    end)

    :ok
  end

  describe "commit_config_change/3" do
    test "atomic write + git commit retourne SHA", %{tmp_dir: tmp_dir} do
      assert {:ok, sha} =
               GitCommitter.commit_config_change("intensity.json", ~s|{"level":"low"}|, "user1")

      assert sha =~ ~r/^[0-9a-f]{40}$/

      assert File.read!(Path.join(tmp_dir, "intensity.json")) == ~s|{"level":"low"}|

      {log, 0} = System.cmd("git", ["log", "--oneline", "-1"], cd: tmp_dir)
      assert log =~ "config: intensity.json updated by user1"
    end

    test "modification subséquente → nouveau commit" do
      {:ok, sha1} = GitCommitter.commit_config_change("a.json", ~s|{"v":1}|, "u1")
      {:ok, sha2} = GitCommitter.commit_config_change("a.json", ~s|{"v":2}|, "u2")

      assert sha1 != sha2
    end

    test "atomic write : pas de fichier .tmp restant après commit", %{tmp_dir: tmp_dir} do
      {:ok, _} = GitCommitter.commit_config_change("clean.json", "{}", "u")

      refute File.exists?(Path.join(tmp_dir, "clean.json.tmp"))
    end

    test "git fail (no commits possible) → {:error, _} cleanup tmp", %{tmp_dir: tmp_dir} do
      :ok = File.write!(Path.join(tmp_dir, "stable.json"), "{}", [:append])
      System.cmd("git", ["add", "stable.json"], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "stable"], cd: tmp_dir, stderr_to_stdout: true)

      # Re-write same content → git commit fails (nothing to commit)
      assert {:error, msg} = GitCommitter.commit_config_change("stable.json", "{}", "u1")
      assert msg =~ "git command failed"

      # tmp file cleaned up
      refute File.exists?(Path.join(tmp_dir, "stable.json.tmp"))
    end

    test "confinement : path traversal `..` rejeté, aucun fichier écrit hors repo", %{
      tmp_dir: tmp_dir
    } do
      escapee = Path.expand(Path.join(tmp_dir, "../pwned.json"))
      File.rm(escapee)

      assert {:error, msg} =
               GitCommitter.commit_config_change("../pwned.json", ~s|{"x":1}|, "attacker")

      assert msg =~ "invalid file_path"
      refute File.exists?(escapee)
    end

    test "confinement : chemin absolu rejeté" do
      assert {:error, msg} =
               GitCommitter.commit_config_change("/etc/pwned.json", "x", "attacker")

      assert msg =~ "invalid file_path"
    end

    test "atomicité : échec git post-rename → fichier restauré à l'état d'origine", %{
      tmp_dir: tmp_dir
    } do
      {:ok, _} = GitCommitter.commit_config_change("r.json", ~s|{"v":"old"}|, "u")
      assert File.read!(Path.join(tmp_dir, "r.json")) == ~s|{"v":"old"}|

      # hook pre-commit qui échoue → force `git commit` à planter APRÈS le rename
      hooks = Path.join([tmp_dir, ".git", "hooks"])
      File.mkdir_p!(hooks)
      File.write!(Path.join(hooks, "pre-commit"), "#!/bin/sh\nexit 1\n")
      File.chmod!(Path.join(hooks, "pre-commit"), 0o755)

      assert {:error, _} = GitCommitter.commit_config_change("r.json", ~s|{"v":"new"}|, "u")

      # le fichier disque est restauré à l'origine, PAS laissé sur "new" (atomicité)
      assert File.read!(Path.join(tmp_dir, "r.json")) == ~s|{"v":"old"}|
      refute File.exists?(Path.join(tmp_dir, "r.json.tmp"))
    end
  end
end
