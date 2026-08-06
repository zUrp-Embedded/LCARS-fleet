defmodule Fleet.Pilot.WorktreeSyncTest do
  @moduledoc """
  `WorktreeSync` REALLY aligns the local clone on `origin/main` — real git (local bare origin +
  clone + advancement), not a stub. This is the anti-hollow-green of the fix: without alignment, the
  delivered file never appears on disk (the original bug). `origin` is a local path → no network, no
  token (the `fetch auth:true` goes through `ForgeAuth.git_env() == []` in test, inert on a local
  remote).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.WorktreeSync

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # bare origin + a seed clone that lands the 1st commit on main (the starting "project").
    origin = Path.join(tmp, "origin.git")
    seed = Path.join(tmp, "seed")
    git!(["init", "--bare", "-b", "main", origin])
    git!(["clone", origin, seed])
    git_in!(seed, ["config", "user.email", "t@lcars"])
    git_in!(seed, ["config", "user.name", "t"])
    commit_push!(seed, "README.md", "v0\n", "init")

    # the local clone = the `/home/projects/<name>` showcase, frozen at start (as at onboarding).
    root = Path.join(tmp, "projects")
    File.mkdir_p!(root)
    proj = Path.join(root, "myproj")
    git!(["clone", origin, proj])

    # unique name → async tests without collision on the GenServer's global name.
    name = :"wt_#{System.unique_integer([:positive])}"
    start_supervised!({WorktreeSync, name: name, projects_root: root})

    %{seed: seed, proj: proj, sync: name}
  end

  test "aligns the local clone on origin/main after an advancement (the deliverable lands on disk)",
       %{seed: seed, proj: proj, sync: sync} do
    # origin advances (the "merge"); the local clone has NOTHING yet (the bug: it stays frozen).
    commit_push!(seed, "hello.sh", "echo hi\n", "feat: hello")
    refute File.exists?(Path.join(proj, "hello.sh"))

    assert :ok = WorktreeSync.sync_now(sync, "fleet/myproj", "main")

    # AFTER: the disk reflects origin/main — same SHA, delivered file present.
    assert File.exists?(Path.join(proj, "hello.sh"))
    assert head(proj) == head(seed)
  end

  test "local clone absent → :ok (nothing to align: the clone is a MIRROR, the truth = main merged on the forge; skip logged debug)",
       %{sync: sync} do
    assert :ok = WorktreeSync.sync_now(sync, "fleet/jamais-clone", "main")
  end

  test "concurrent syncs on the same worktree: serialized, all :ok and clone aligned (no index.lock)",
       %{seed: seed, proj: proj, sync: sync} do
    commit_push!(seed, "hello.sh", "echo hi\n", "feat: hello")

    results =
      1..6
      |> Enum.map(fn _ ->
        Task.async(fn -> WorktreeSync.sync_now(sync, "fleet/myproj", "main") end)
      end)
      |> Task.await_many(30_000)

    # The GenServer serializes (one git at a time) → six concurrent alignments don't trample each other.
    assert Enum.all?(results, &(&1 == :ok))
    assert head(proj) == head(seed)
  end

  defp commit_push!(dir, file, content, msg) do
    File.write!(Path.join(dir, file), content)
    git_in!(dir, ["add", "-A"])
    git_in!(dir, ["commit", "-m", msg])
    git_in!(dir, ["push", "origin", "main"])
  end

  defp git!(args), do: {_, 0} = System.cmd("git", args, stderr_to_stdout: true)

  defp git_in!(dir, args),
    do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp head(dir),
    do: System.cmd("git", ["-C", dir, "rev-parse", "HEAD"]) |> elem(0) |> String.trim()
end
