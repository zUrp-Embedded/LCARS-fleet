defmodule Fleet.Spawner.PodWardenGCTest do
  # Serial: these tests change the node-global filesystem roots.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Fleet.Spawner.PodWarden, as: W

  setup %{tmp_dir: tmp} do
    state_root = Path.join(tmp, "state")
    pod_root = Path.join(tmp, "pods")
    Application.put_env(:lcars_fleet, :spawner_state_fs_root, state_root)
    Application.put_env(:lcars_fleet, :spawner_pod_dir_root, pod_root)

    on_exit(fn ->
      Application.delete_env(:lcars_fleet, :spawner_state_fs_root)
      Application.delete_env(:lcars_fleet, :spawner_pod_dir_root)
    end)

    %{state_root: state_root, pod_root: pod_root}
  end

  # Returns the state directory; fixtures cover each scope scanned by the warden.
  defp write_state!(root, scope, pod_id, phase) do
    dir = Path.join([root, scope, pod_id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "state.json"), Jason.encode!(%{"phase" => phase, "v" => 1}))
    dir
  end

  defp write_pod_dir!(pod_root, pod_id) do
    dir = Path.join(pod_root, "pod_#{pod_id}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "clone_marker"), "stale")
    dir
  end

  test "GC erases ONLY the terminal-orphan tombstone; spares non-terminal + live, 2-tick grace",
       %{state_root: sr, pod_root: pr} do
    done_state = write_state!(sr, "pods", "done", "succeeded")
    done_pod = write_pod_dir!(pr, "done")

    # Failed orphan tombstones are GC candidates too, even without redispatch.
    failed_state = write_state!(sr, "pods", "failed-orphan", "failed")
    failed_pod = write_pod_dir!(pr, "failed-orphan")
    inflight_state = write_state!(sr, "runs", "inflight", "monitoring")
    inflight_pod = write_pod_dir!(pr, "inflight")
    # Keep terminal-but-live pods to avoid racing a respawn.
    liveterm_state = write_state!(sr, "pipes", "live-term", "succeeded")
    liveterm_pod = write_pod_dir!(pr, "live-term")

    live = MapSet.new(["live-term"])

    suspects1 = W.sweep_pod_dir_gc(live, MapSet.new())
    assert MapSet.equal?(suspects1, MapSet.new(["done", "failed-orphan"]))
    assert File.exists?(done_pod)
    assert File.exists?(done_state)
    assert File.exists?(failed_pod)
    assert File.exists?(failed_state)

    suspects2 = W.sweep_pod_dir_gc(live, suspects1)
    assert MapSet.equal?(suspects2, MapSet.new())

    refute File.exists?(done_pod)
    refute File.exists?(done_state)
    refute File.exists?(failed_pod)
    refute File.exists?(failed_state)

    assert File.exists?(inflight_pod)
    assert File.exists?(inflight_state)
    assert File.exists?(liveterm_pod)
    assert File.exists?(liveterm_state)
  end

  test "R1-33: a dir whose NAME is not a valid pod_id (`.hidden-evil`) is NEVER scanned/GC'd",
       %{state_root: sr, pod_root: pr} do
    # An invalid pod ID is not evidence of an owned directory; leave it untouched.
    foreign_state = write_state!(sr, "pods", ".hidden-evil", "succeeded")
    foreign_pod = write_pod_dir!(pr, ".hidden-evil")

    valid_state = write_state!(sr, "pods", "issue-9-engineer", "succeeded")
    valid_pod = write_pod_dir!(pr, "issue-9-engineer")

    live = MapSet.new()
    suspects1 = W.sweep_pod_dir_gc(live, MapSet.new())
    assert MapSet.equal?(suspects1, MapSet.new(["issue-9-engineer"]))

    _ = W.sweep_pod_dir_gc(live, suspects1)

    assert File.exists?(foreign_state), "a non-pod_id dir must NEVER be GC'd (R1-33)"
    assert File.exists?(foreign_pod)
    refute File.exists?(valid_state)
    refute File.exists?(valid_pod)
  end
end
