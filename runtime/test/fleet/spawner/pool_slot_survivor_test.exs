defmodule Fleet.Spawner.PoolSlotSurvivorTest do
  @moduledoc """
  The slot a DEAD registry still owes to a LIVE holder.

  `PoolSlot` exists so two processes never share a deterministic `session_id`, and it used to read
  only the in-memory registry. After a BEAM restart that registry is empty while orphaned bwrap
  holders are still alive — and the same index was handed out again, which is the collision the
  module is for. This pins the survivor half, and that it is LIVENESS and nothing else that counts.
  """
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Fleet.Spawner.PoolSlot

  defp snapshot(root, pod_id, role, repo, pool) do
    dir = Path.join([root, "pods", pod_id])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "state.json"),
      Jason.encode!(%{
        "v" => 1,
        "session_id" => "sid-#{pod_id}",
        "phase" => "monitoring",
        "slot" => %{"role" => role, "repo" => repo, "pool" => pool}
      })
    )
  end

  test "a LIVE survivor holds its index across an empty registry", %{tmp_dir: root} do
    snapshot(root, "pod-orphan", "engineer", 7, 1)

    taken =
      PoolSlot.taken_slots("engineer", 7, state_fs_root: root, alive_fun: fn _ -> true end)

    assert MapSet.member?(taken, 1)
  end

  test "a DEAD one does not — a wasted seat is the cheaper mistake, but not a free one", %{
    tmp_dir: root
  } do
    snapshot(root, "pod-dead", "engineer", 7, 1)

    taken =
      PoolSlot.taken_slots("engineer", 7, state_fs_root: root, alive_fun: fn _ -> false end)

    refute MapSet.member?(taken, 1)
  end

  test "another (role, repo) is not this pod's business", %{tmp_dir: root} do
    snapshot(root, "pod-other-role", "qualifier", 7, 1)
    snapshot(root, "pod-other-repo", "engineer", 99, 2)

    taken =
      PoolSlot.taken_slots("engineer", 7, state_fs_root: root, alive_fun: fn _ -> true end)

    assert MapSet.size(taken) == 0
  end

  test "a snapshot with NO slot is skipped, never guessed", %{tmp_dir: root} do
    # A pod outside the managed fan-out (recall, hand-built) writes `"slot": null`. Guessing an
    # index for it would take a seat nobody holds.
    dir = Path.join([root, "pods", "pod-slotless"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "state.json"), Jason.encode!(%{"v" => 1, "slot" => nil}))

    assert MapSet.size(
             PoolSlot.taken_slots("engineer", 7, state_fs_root: root, alive_fun: fn _ -> true end)
           ) == 0
  end

  test "an UNREADABLE snapshot is skipped and does not raise", %{tmp_dir: root} do
    dir = Path.join([root, "pods", "pod-corrupt"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "state.json"), "{not json")

    assert MapSet.size(
             PoolSlot.taken_slots("engineer", 7, state_fs_root: root, alive_fun: fn _ -> true end)
           ) == 0
  end
end
