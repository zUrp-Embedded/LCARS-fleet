defmodule Fleet.Spawner.SeedStoreTest do
  @moduledoc "Seed-store checkpoint (pod-seed v2)."
  # async:false — `seed_store_root` is global config (Application env).
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.Spawner.SeedStore

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "seedroot")
    Fleet.Spawner.TestEnv.put_env_restoring(:fleet_spawner, :seed_store_root, root)

    %{tmp: tmp, root: root}
  end

  defp make_jsonl(pod_dir, slug, uuid, content) do
    dir = Path.join([pod_dir, ".claude", "projects", slug])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{uuid}.jsonl")
    File.write!(path, content)
    path
  end

  test "checkpoint: keeps the FIRST ROUND only (up to the 1st assistant) + workflow_map", %{
    tmp: tmp,
    root: root
  } do
    pod_dir = Path.join(tmp, "pod")

    content =
      ~s({"type":"user","message":"r1"}\n{"type":"assistant","message":"ok"}\n{"type":"user","message":"r2"}\n)

    # The live jsonl's uuid ("uuid-abc") is NOT the stored identity; the passed builder is.
    make_jsonl(pod_dir, "-home-x-poc8-engineer", "uuid-abc", content)

    assert :ok = SeedStore.checkpoint(pod_dir, "poc-8", "engineer", "builder-det")

    seed = File.read!(Path.join([root, "poc-8", "pods", "engineer.jsonl"]))
    # round 1 (user + assistant) kept; round 2 discarded.
    assert seed =~ "r1"
    assert seed =~ "assistant"
    refute seed =~ "r2"

    map = Path.join([root, "poc-8", "pods", "engineer.json"]) |> File.read!() |> Jason.decode!()

    # uuid = the passed builder (single source). slug = cwd-slug of the live jsonl (content).
    assert %{
             "uuid" => "builder-det",
             "slug" => "-home-x-poc8-engineer",
             "role" => "engineer",
             "projet" => "poc-8"
           } = map
  end

  test "checkpoint: workflow_map = passed builder, NOT the live jsonl's uuid (/clear rotation)",
       %{
         tmp: tmp,
         root: root
       } do
    pod_dir = Path.join(tmp, "pod")
    old = make_jsonl(pod_dir, "slug", "old-uuid", "old\n")
    File.touch!(old, {{2020, 1, 1}, {0, 0, 0}})
    make_jsonl(pod_dir, "slug", "new-uuid", "new\n")

    # Two live jsonl files (a `/clear` rotated the uuid). Contract: the workflow_map carries the
    # PASSED builder (single source), INDEPENDENTLY of the live jsonl's uuid — neither the old nor
    # the recent one.
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det")

    map = Path.join([root, "p", "pods", "engineer.json"]) |> File.read!() |> Jason.decode!()
    assert map["uuid"] == "builder-det"
    refute map["uuid"] == "new-uuid"

    # The CONTENT always comes from the ACTIVE jsonl = the most recent (the live session, post-/clear).
    assert File.read!(Path.join([root, "p", "pods", "engineer.jsonl"])) == "new\n"
  end

  test "checkpoint: no JSONL → :none, nothing written", %{tmp: tmp, root: root} do
    pod_dir = Path.join(tmp, "empty-pod")
    File.mkdir_p!(pod_dir)

    assert :none = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det")
    refute File.exists?(Path.join(root, "p"))
  end

  test "slugify: reproduces the real claude slug (proven 2.1.183)" do
    assert SeedStore.slugify("/home/starfleet/pods/pod_fleet-poc-8-issue-6-consultant/workspace") ==
             "-home-starfleet-pods-pod-fleet-poc-8-issue-6-consultant-workspace"

    assert SeedStore.slugify("/home/x/resume-test__9c62d00f") == "-home-x-resume-test--9c62d00f"
  end

  test "read_map: workflow_map + jsonl present → {:ok, uuid}, otherwise :none", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det")

    # read_map re-reads the workflow_map's uuid = the stored builder, NOT the live jsonl's uuid ("u1").
    assert {:ok, %{uuid: "builder-det"}} = SeedStore.read_map("p", "engineer")
    assert :none = SeedStore.read_map("p", "inexistant")
  end

  test "restore: cp the seed at the recall cwd's slug, findable by --resume", %{tmp: tmp} do
    seed = Path.join(tmp, "seed.jsonl")
    File.write!(seed, "mem\n")
    pod_dir = Path.join(tmp, "recallpod")

    {:ok, dest} = SeedStore.restore(seed, pod_dir, "/home/r/recallpod", "u9")

    assert dest == Path.join([pod_dir, ".claude", "projects", "-home-r-recallpod", "u9.jsonl"])
    assert File.read!(dest) == "mem\n"
  end

  test "Spawner.recall: no seed for (project,role) → {:error, :no_seed}" do
    assert {:error, :no_seed} = Fleet.Spawner.recall("projet-inexistant", "engineer")
  end

  # ============================================================
  # Confinement E (WI-E1) — a non-slug project/role name NEVER traverses the seed-store.
  # ============================================================

  test "checkpoint: traversing project (../evil) → REFUSED, nothing written outside the store", %{
    tmp: tmp,
    root: root
  } do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")

    # Escape target: `<root>/../evil/pods/...` = a SIBLING directory of the seed-store root.
    evil_dir = Path.expand(Path.join(root, "../evil"))

    assert {:error, _} = SeedStore.checkpoint(pod_dir, "../evil", "engineer", "builder-det")

    # Proven regression: without the slug+confinement guard, `Path.join([root, "../evil", "pods"])`
    # would write `engineer.jsonl` HERE, outside the root. The guard makes it unrepresentable.
    refute File.exists?(evil_dir)
    refute File.exists?(Path.join([root, "..", "evil"]))
  end

  test "checkpoint: traversing role (a/b) → REFUSED", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "p", "a/b", "builder-det")
  end

  test "checkpoint: empty / NUL / control names → REFUSED", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "", "engineer", "builder-det")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "ok\x00evil", "engineer", "builder-det")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "ok\nevil", "engineer", "builder-det")
  end

  test "checkpoint: valid name (my_checkpoint-1) → accepted", %{tmp: tmp, root: root} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "my_checkpoint-1", "engineer", "builder-det")
    assert File.exists?(Path.join([root, "my_checkpoint-1", "pods", "engineer.jsonl"]))
  end

  test "read_map: traversing project → :none (does not read outside the store)", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det")
    assert :none = SeedStore.read_map("../p", "engineer")
    assert :none = SeedStore.read_map("p", "../engineer")
  end

  test "restore: uuid escaping the pod_dir → REFUSED (fail-loud raise), no write outside the pod",
       %{
         tmp: tmp
       } do
    seed = Path.join(tmp, "seed.jsonl")
    File.write!(seed, "mem\n")
    pod_dir = Path.join(tmp, "recallpod")

    # hostile uuid (read from a corrupted seed-map): the write leaf is `pod_dir/.claude/projects/
    # <slug>/` (3 levels under the pod) → 4 `../` are needed to cross the pod_dir and target a host
    # file (`tmp/escaped.jsonl`). `restore` confines `dest` under `pod_dir` via `under_root?` BEFORE
    # the `cp!`: an escape MUST raise (the caller folds the raise onto transition_failed, the pod
    # does not launch). A uuid staying under the pod (e.g. `../../x` → `.claude/x.jsonl`) is
    # legitimate — the pod is ephemeral and owned; the only real vector closed here is writing
    # OUTSIDE the pod.
    escape_target = Path.expand(Path.join(tmp, "escaped.jsonl"))
    File.rm(escape_target)

    assert_raise ArgumentError, fn ->
      SeedStore.restore(seed, pod_dir, "/home/r/recallpod", "../../../../escaped")
    end

    refute File.exists?(escape_target)
  end
end
