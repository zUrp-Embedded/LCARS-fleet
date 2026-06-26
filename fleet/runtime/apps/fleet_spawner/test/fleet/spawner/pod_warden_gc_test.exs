defmodule Fleet.Spawner.PodWardenGCTest do
  # GC pod_dir bout-en-bout sur un faux state-base/pod-base (tmp_dir). async: false : pose la config
  # GLOBALE des racines FS (comme pod_test.exs), donc sérialisé avec les autres tests qui les touchent.
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

  # state.json sous `<root>/<scope>/<pod_id>/` (le scan couvre tous les scopes) ; rend le state-DIR.
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

  test "GC efface SEULEMENT la tombstone terminale-orpheline ; épargne non-terminale + vivante, grace 2-tick",
       %{state_root: sr, pod_root: pr} do
    # terminale + orpheline (pas dans `live`) → doit être GC, mais après la grace.
    done_state = write_state!(sr, "pods", "done", "succeeded")
    done_pod = write_pod_dir!(pr, "done")
    # non-terminale (en vol) + orpheline → épargnée (recovery :resume/:recreate intacte).
    inflight_state = write_state!(sr, "runs", "inflight", "monitoring")
    inflight_pod = write_pod_dir!(pr, "inflight")
    # terminale MAIS vivante (pod_id dans le registry) → épargnée (race re-spawn).
    liveterm_state = write_state!(sr, "pipes", "live-term", "succeeded")
    liveterm_pod = write_pod_dir!(pr, "live-term")

    live = MapSet.new(["live-term"])

    # Tick 1 (grace) : rien n'est effacé, "done" devient seulement suspecte.
    suspects1 = W.sweep_pod_dir_gc(live, MapSet.new())
    assert MapSet.equal?(suspects1, MapSet.new(["done"]))
    assert File.exists?(done_pod)
    assert File.exists?(done_state)

    # Tick 2 : "done" confirmée → state-dir ET pod_dir effacés. Tout le reste intact.
    suspects2 = W.sweep_pod_dir_gc(live, suspects1)
    assert MapSet.equal?(suspects2, MapSet.new())

    refute File.exists?(done_pod)
    refute File.exists?(done_state)

    assert File.exists?(inflight_pod)
    assert File.exists?(inflight_state)
    assert File.exists?(liveterm_pod)
    assert File.exists?(liveterm_state)
  end
end
