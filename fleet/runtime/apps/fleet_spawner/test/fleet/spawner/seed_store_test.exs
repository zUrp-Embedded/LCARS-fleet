defmodule Fleet.Spawner.SeedStoreTest do
  @moduledoc "Seed-store checkpoint (chantier pod-seed v2)."
  # async:false — `seed_store_root` est une config globale (Application env).
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.Spawner.SeedStore

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "seedroot")
    prev = Application.get_env(:fleet_spawner, :seed_store_root)
    Application.put_env(:fleet_spawner, :seed_store_root, root)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_spawner, :seed_store_root, prev),
        else: Application.delete_env(:fleet_spawner, :seed_store_root)
    end)

    %{tmp: tmp, root: root}
  end

  defp make_jsonl(pod_dir, slug, uuid, content) do
    dir = Path.join([pod_dir, ".claude", "projects", slug])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{uuid}.jsonl")
    File.write!(path, content)
    path
  end

  test "checkpoint : cp le JSONl actif → seed-store + carte {uuid,slug}", %{tmp: tmp, root: root} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "-home-x-poc8-engineer", "uuid-abc", "{\"x\":1}\n")

    assert :ok = SeedStore.checkpoint(pod_dir, "poc-8", "engineer")

    assert File.read!(Path.join([root, "poc-8", "pods", "engineer.jsonl"])) == "{\"x\":1}\n"

    map = Path.join([root, "poc-8", "pods", "engineer.json"]) |> File.read!() |> Jason.decode!()

    assert %{
             "uuid" => "uuid-abc",
             "slug" => "-home-x-poc8-engineer",
             "role" => "engineer",
             "projet" => "poc-8"
           } = map
  end

  test "checkpoint : prend le JSONl le PLUS RÉCENT (rotation /clear)", %{tmp: tmp, root: root} do
    pod_dir = Path.join(tmp, "pod")
    old = make_jsonl(pod_dir, "slug", "old-uuid", "old\n")
    File.touch!(old, {{2020, 1, 1}, {0, 0, 0}})
    make_jsonl(pod_dir, "slug", "new-uuid", "new\n")

    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer")

    map = Path.join([root, "p", "pods", "engineer.json"]) |> File.read!() |> Jason.decode!()
    assert map["uuid"] == "new-uuid"
    assert File.read!(Path.join([root, "p", "pods", "engineer.jsonl"])) == "new\n"
  end

  test "checkpoint : aucun JSONl → :none, rien écrit", %{tmp: tmp, root: root} do
    pod_dir = Path.join(tmp, "empty-pod")
    File.mkdir_p!(pod_dir)

    assert :none = SeedStore.checkpoint(pod_dir, "p", "engineer")
    refute File.exists?(Path.join(root, "p"))
  end

  test "slugify : reproduit le slug claude réel (proven 2.1.183)" do
    assert SeedStore.slugify("/home/starfleet/pods/pod_fleet-poc-8-issue-6-consultant/workspace") ==
             "-home-starfleet-pods-pod-fleet-poc-8-issue-6-consultant-workspace"

    assert SeedStore.slugify("/home/x/resume-test__9c62d00f") == "-home-x-resume-test--9c62d00f"
  end

  test "read_map : carte + jsonl présents → {:ok, uuid}, sinon :none", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer")

    assert {:ok, %{uuid: "u1"}} = SeedStore.read_map("p", "engineer")
    assert :none = SeedStore.read_map("p", "inexistant")
  end

  test "restore : cp le seed au slug du cwd de rappel, retrouvable par --resume", %{tmp: tmp} do
    seed = Path.join(tmp, "seed.jsonl")
    File.write!(seed, "mem\n")
    pod_dir = Path.join(tmp, "recallpod")

    {:ok, dest} = SeedStore.restore(seed, pod_dir, "/home/r/recallpod", "u9")

    assert dest == Path.join([pod_dir, ".claude", "projects", "-home-r-recallpod", "u9.jsonl"])
    assert File.read!(dest) == "mem\n"
  end

  test "Spawner.recall : aucun seed pour (projet,role) → {:error, :no_seed}" do
    assert {:error, :no_seed} = Fleet.Spawner.recall("projet-inexistant", "engineer")
  end
end
