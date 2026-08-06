defmodule Fleet.Spawner.PodWardenGCTest do
  # End-to-end pod_dir GC on a fake state-base/pod-base (tmp_dir). async: false: sets the GLOBAL
  # FS-roots config (like pod_test.exs), hence serialized with the other tests that touch them.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Fleet.Spawner.PodWarden, as: W

  setup %{tmp_dir: tmp} do
    state_root = Path.join(tmp, "state")
    pod_root = Path.join(tmp, "pods")
    Application.put_env(:fleet_spawner, :state_fs_root, state_root)
    Application.put_env(:fleet_spawner, :pod_dir_root, pod_root)

    on_exit(fn ->
      Application.delete_env(:fleet_spawner, :state_fs_root)
      Application.delete_env(:fleet_spawner, :pod_dir_root)
    end)

    %{state_root: state_root, pod_root: pod_root}
  end

  # state.json under `<root>/<scope>/<pod_id>/` (the scan covers all scopes); returns the state-DIR.
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
    # terminal + orphan (not in `live`) → must be GC'd, but after the grace.
    done_state = write_state!(sr, "pods", "done", "succeeded")
    done_pod = write_pod_dir!(pr, "done")

    # terminal-DIED `failed` + orphan → GC-able too (G10: otherwise eternal leak of a failed never
    # re-dispatched; recreate re-clones fresh, nothing to lose). Same treatment as `succeeded`.
    failed_state = write_state!(sr, "pods", "failed-orphan", "failed")
    failed_pod = write_pod_dir!(pr, "failed-orphan")
    # non-terminal (in flight) + orphan → spared (recovery :resume/:recreate intact).
    inflight_state = write_state!(sr, "runs", "inflight", "monitoring")
    inflight_pod = write_pod_dir!(pr, "inflight")
    # terminal BUT live (pod_id in the registry) → spared (re-spawn race).
    liveterm_state = write_state!(sr, "pipes", "live-term", "succeeded")
    liveterm_pod = write_pod_dir!(pr, "live-term")

    live = MapSet.new(["live-term"])

    # Tick 1 (grace): nothing is erased, "done" AND "failed-orphan" only become suspects.
    suspects1 = W.sweep_pod_dir_gc(live, MapSet.new())
    assert MapSet.equal?(suspects1, MapSet.new(["done", "failed-orphan"]))
    assert File.exists?(done_pod)
    assert File.exists?(done_state)
    assert File.exists?(failed_pod)
    assert File.exists?(failed_state)

    # Tick 2: "done" AND "failed-orphan" confirmed → state-dir AND pod_dir erased. The rest intact.
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
    # FOREIGN dir: non-`valid_pod_id?` name (leading dot) + terminal state.json + pod_dir → must
    # SURVIVE (never produced by a spawn, so not our leak to clean; never rm_rf an unknown dir).
    foreign_state = write_state!(sr, "pods", ".hidden-evil", "succeeded")
    foreign_pod = write_pod_dir!(pr, ".hidden-evil")

    # control: a VALID terminal-orphan pod_id does get GC'd after the grace.
    valid_state = write_state!(sr, "pods", "issue-9-engineer", "succeeded")
    valid_pod = write_pod_dir!(pr, "issue-9-engineer")

    live = MapSet.new()
    suspects1 = W.sweep_pod_dir_gc(live, MapSet.new())
    # the foreign dir is not even SUSPECT (never scanned) — only the valid one is.
    assert MapSet.equal?(suspects1, MapSet.new(["issue-9-engineer"]))

    _ = W.sweep_pod_dir_gc(live, suspects1)

    assert File.exists?(foreign_state), "a non-pod_id dir must NEVER be GC'd (R1-33)"
    assert File.exists?(foreign_pod)
    refute File.exists?(valid_state)
    refute File.exists?(valid_pod)
  end
end
