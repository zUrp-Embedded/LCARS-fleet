defmodule Fleet.Pilot.ProjectOnboardCompensationTest do
  @moduledoc """
  Compensation of a FAILED onboard/import — the mid-sequence failure must not leave half-created
  state that wedges the retry (repo 409 + dir-exists walls, host rm the only way out — seen LIVE).

  E2E against a REAL `file://` forge: the stubbed `:forge_repo` creates an actual bare repo on
  disk (create), fails `protect_branch` (the LAST step — everything is built when the failure
  lands), and records `delete_repo`. Git (clone/scaffold/commit/push) runs for real.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ProjectOnboard

  @moduletag :tmp_dir

  # Forge stub over a real on-disk `file://` forge. Runs IN the test process (onboard is plain
  # function calls) → coordination via the process dictionary + self-messages.
  defmodule FileForge do
    def generate_repo(_template, _name, _opts), do: {:error, :template_missing}

    def create_repo(name, _opts) do
      root = Process.get(:file_forge_root)
      src = Path.join(root, "_src_#{name}_#{System.unique_integer([:positive])}")
      bare = Path.join([root, "fleet", "#{name}.git"])
      File.mkdir_p!(src)
      File.mkdir_p!(Path.dirname(bare))

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
      File.write!(Path.join(src, "SEED"), "seed")
      {_, 0} = System.cmd("git", ["-C", src, "add", "."], stderr_to_stdout: true)

      {_, 0} =
        System.cmd(
          "git",
          ["-C", src, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"],
          stderr_to_stdout: true
        )

      {_, 0} = System.cmd("git", ["clone", "-q", "--bare", src, bare], stderr_to_stdout: true)
      {:ok, "fleet/#{name}"}
    end

    def protect_branch(_repo, _rule, _fc), do: Process.get(:protect_result, :ok)

    def default_branch(full_name, _fc) do
      if File.dir?(bare_path(full_name)), do: {:ok, "main"}, else: {:error, {:http, 404, "gone"}}
    end

    def delete_repo(full_name, _fc) do
      File.rm_rf!(bare_path(full_name))
      send(self(), {:forge_deleted, full_name})
      :ok
    end

    def branch_exists?(_full_name, _branch, _fc), do: false

    defp bare_path(full_name), do: Path.join(Process.get(:file_forge_root), "#{full_name}.git")
  end

  defmodule Humans do
    def user_exists?(_h, _fc), do: {:ok, true}
    def team_member?(_org, _team, _h, _fc), do: {:ok, true}
  end

  defp opts(tmp) do
    forge_root = Path.join(tmp, "forge")
    File.mkdir_p!(forge_root)
    Process.put(:file_forge_root, forge_root)

    [
      projects_root: Path.join(tmp, "projects"),
      work_root: Path.join(tmp, "work"),
      base_url: "file://" <> forge_root,
      forge_repo: FileForge,
      forge_users: Humans,
      sleeper: fn _ms -> :ok end,
      ensure_architect: fn _repo, _o -> {:ok, "arch-stub"} end
    ]
  end

  test "a LATE onboard failure (protect_branch) compensates: forge repo deleted, dirs removed, retry possible",
       %{tmp_dir: tmp} do
    o = opts(tmp)
    Process.put(:protect_result, {:error, {:http, 500, "boom"}})

    assert {:error, {:protect_main, _}} = ProjectOnboard.onboard("phoenix", o)

    # The unwind: the forge repo THIS call created is deleted, both dirs are gone — nothing left to
    # wedge a retry on the refute_existing / create_repo-409 walls.
    assert_received {:forge_deleted, "fleet/phoenix"}
    refute File.exists?(Path.join(o[:projects_root], "phoenix"))
    refute File.exists?(Path.join(o[:work_root], "phoenix"))

    # The RETRY of the same onboard now goes through cleanly (fresh create, full sequence).
    Process.put(:protect_result, :ok)
    assert {:ok, %{repo: "fleet/phoenix"}} = ProjectOnboard.onboard("phoenix", o)
    assert File.dir?(Path.join(o[:projects_root], "phoenix"))
    assert File.dir?(Path.join(o[:work_root], "phoenix"))
  end

  test "a successful onboard compensates NOTHING (dirs + repo stay)", %{tmp_dir: tmp} do
    o = opts(tmp)
    Process.put(:protect_result, :ok)

    assert {:ok, %{repo: "fleet/apollo", architect: %{status: "up"}}} =
             ProjectOnboard.onboard("apollo", o)

    refute_received {:forge_deleted, _}
    assert File.dir?(Path.join(o[:projects_root], "apollo"))
    assert File.dir?(Path.join(o[:work_root], "apollo"))
  end

  test "a LATE import failure compensates the DIRS ONLY — the pre-existing repo is NEVER deleted",
       %{tmp_dir: tmp} do
    o = opts(tmp)
    # The repo pre-exists on the forge (created out-of-band, as an import target is).
    {:ok, "fleet/heritage"} = FileForge.create_repo("heritage", [])
    Process.put(:protect_result, {:error, {:http, 500, "boom"}})

    assert {:error, {:protect_main, _}} = ProjectOnboard.import("fleet/heritage", o)

    # Dirs unwound; the repo was NOT ours to delete.
    refute_received {:forge_deleted, _}
    refute File.exists?(Path.join(o[:projects_root], "heritage"))
    refute File.exists?(Path.join(o[:work_root], "heritage"))
    assert File.dir?(Path.join([tmp, "forge", "fleet", "heritage.git"]))

    # Retry clean.
    Process.put(:protect_result, :ok)
    assert {:ok, %{repo: "fleet/heritage"}} = ProjectOnboard.import("fleet/heritage", o)
  end
end
