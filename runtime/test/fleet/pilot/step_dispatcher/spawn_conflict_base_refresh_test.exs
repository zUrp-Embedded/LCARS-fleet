defmodule Fleet.Pilot.StepDispatcher.SpawnConflictBaseRefreshTest do
  @moduledoc """
  A0.5 — a conflict rework's `refs/lcars/base` follows the moved base (measured hole, bench
  2026-08-18: a live instance-scoped pod, re-briefed in place BY DESIGN, kept the base of its
  build and merged it into itself — "Already up to date", twice, budget burned, arch escalated
  over a conflict the pod was never shown).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher.Spawn

  defmodule RefreshSpy do
    def refresh_work_base(pod_id, project) do
      send(self(), {:refreshed, pod_id, project["pr_base_branch"]})
      :ok
    end
  end

  defmodule RefreshDown do
    def refresh_work_base(_pod_id, _project), do: {:error, {:refresh_fetch_failed, 128, "boom"}}
  end

  defmodule RefreshGone do
    def refresh_work_base(_pod_id, _project), do: {:error, :not_found}
  end

  defmodule NoRefresh do
  end

  test "live pod (:proceed) → the base ref is refreshed, with the PR's base branch" do
    project = %{"pr_base_branch" => "main"}
    assert :ok = Spawn.refresh_conflict_base(:proceed, RefreshSpy, "pod-x", project)
    assert_received {:refreshed, "pod-x", "main"}
  end

  test "cold reprovision already re-pins (6-135) → no double gesture" do
    assert :ok =
             Spawn.refresh_conflict_base(:ready_needs_reprovision, RefreshSpy, "pod-x", %{
               "pr_base_branch" => "main"
             })

    refute_received {:refreshed, _, _}
  end

  test "refresh FAILS on a live pod → the dispatch is SKIPPED, never a brief on a stale base" do
    assert {:skipped, :stale_base_unrefreshed} =
             Spawn.refresh_conflict_base(:proceed, RefreshDown, "pod-x", %{
               "pr_base_branch" => "main"
             })
  end

  test "pod not registered → fine: a fresh spawn pins its own base at clone" do
    assert :ok =
             Spawn.refresh_conflict_base(:proceed, RefreshGone, "pod-x", %{
               "pr_base_branch" => "main"
             })
  end

  test "a spawner stub without the function is tolerated (test-harness compatibility)" do
    assert :ok =
             Spawn.refresh_conflict_base(:proceed, NoRefresh, "pod-x", %{
               "pr_base_branch" => "main"
             })
  end

  # ── the git gesture itself, on a real repo: the ref moves, the working tree does not ──
  @tag :tmp_dir
  test "Phase.Clone.refresh_work_base moves refs/lcars/base to the CURRENT origin tip", %{
    tmp_dir: dir
  } do
    origin = Path.join(dir, "origin")
    ws = Path.join(dir, "ws")
    g = fn d, args -> {_, 0} = System.cmd("git", ["-C", d | args], stderr_to_stdout: true) end

    File.mkdir_p!(origin)
    g.(origin, ["init", "-q", "-b", "main"])
    g.(origin, ["config", "user.name", "h"])
    g.(origin, ["config", "user.email", "h@x"])
    File.write!(Path.join(origin, "f.txt"), "v1")
    g.(origin, ["add", "-A"])
    g.(origin, ["commit", "-qm", "v1"])

    {_, 0} = System.cmd("git", ["clone", "-q", origin, ws], stderr_to_stdout: true)
    g.(ws, ["update-ref", "refs/lcars/base", "HEAD"])
    {stale, 0} = System.cmd("git", ["-C", ws, "rev-parse", "refs/lcars/base"], [])

    # the base MOVES upstream (another brick landed)
    File.write!(Path.join(origin, "f.txt"), "v2")
    g.(origin, ["add", "-A"])
    g.(origin, ["commit", "-qm", "v2"])
    {tip, 0} = System.cmd("git", ["-C", origin, "rev-parse", "HEAD"], [])

    assert {:ok, :refreshed} =
             Fleet.ProjectBootstrap.Phase.Clone.refresh_work_base(ws, %{
               "pr_base_branch" => "main"
             })

    {now, 0} = System.cmd("git", ["-C", ws, "rev-parse", "refs/lcars/base"], [])
    assert String.trim(now) == String.trim(tip)
    refute String.trim(now) == String.trim(stale)
    # the working tree did NOT move — only the ref did (context preserved)
    assert File.read!(Path.join(ws, "f.txt")) == "v1"
  end

  test "a map without pr_base_branch is refused — the caller has not said which base moved" do
    assert {:error, :no_pr_base_branch} =
             Fleet.ProjectBootstrap.Phase.Clone.refresh_work_base("/nonexistent", %{})
  end
end
