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

  test "checkpoint : garde le PREMIER ROUND seul (jusqu'au 1er assistant) + workflow_map", %{
    tmp: tmp,
    root: root
  } do
    pod_dir = Path.join(tmp, "pod")

    content =
      ~s({"type":"user","message":"r1"}\n{"type":"assistant","message":"ok"}\n{"type":"user","message":"r2"}\n)

    # L'uuid du jsonl vivant ("uuid-abc") n'est PLUS l'identité stockée ; le builder passé l'est.
    make_jsonl(pod_dir, "-home-x-poc8-engineer", "uuid-abc", content)

    assert :ok = SeedStore.checkpoint(pod_dir, "poc-8", "engineer", "builder-det")

    seed = File.read!(Path.join([root, "poc-8", "pods", "engineer.jsonl"]))
    # round 1 (user + assistant) gardé ; round 2 jeté.
    assert seed =~ "r1"
    assert seed =~ "assistant"
    refute seed =~ "r2"

    map = Path.join([root, "poc-8", "pods", "engineer.json"]) |> File.read!() |> Jason.decode!()

    # uuid = le builder passé (source unique). slug = cwd-slug du jsonl vivant (contenu).
    assert %{
             "uuid" => "builder-det",
             "slug" => "-home-x-poc8-engineer",
             "role" => "engineer",
             "projet" => "poc-8"
           } = map
  end

  test "checkpoint : workflow_map = builder passé, PAS l'uuid du jsonl vivant (rotation /clear)",
       %{
         tmp: tmp,
         root: root
       } do
    pod_dir = Path.join(tmp, "pod")
    old = make_jsonl(pod_dir, "slug", "old-uuid", "old\n")
    File.touch!(old, {{2020, 1, 1}, {0, 0, 0}})
    make_jsonl(pod_dir, "slug", "new-uuid", "new\n")

    # Deux jsonl vivants (un `/clear` a rotaté l'uuid). NOUVEAU contrat : la workflow_map porte le BUILDER
    # passé (source unique), INDÉPENDAMMENT de l'uuid du jsonl vivant — ni l'ancien, ni le récent.
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det")

    map = Path.join([root, "p", "pods", "engineer.json"]) |> File.read!() |> Jason.decode!()
    assert map["uuid"] == "builder-det"
    refute map["uuid"] == "new-uuid"

    # Le CONTENU vient toujours du jsonl ACTIF = le plus récent (la session vivante, post-/clear).
    assert File.read!(Path.join([root, "p", "pods", "engineer.jsonl"])) == "new\n"
  end

  test "checkpoint : aucun JSONl → :none, rien écrit", %{tmp: tmp, root: root} do
    pod_dir = Path.join(tmp, "empty-pod")
    File.mkdir_p!(pod_dir)

    assert :none = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det")
    refute File.exists?(Path.join(root, "p"))
  end

  test "slugify : reproduit le slug claude réel (proven 2.1.183)" do
    assert SeedStore.slugify("/home/starfleet/pods/pod_fleet-poc-8-issue-6-consultant/workspace") ==
             "-home-starfleet-pods-pod-fleet-poc-8-issue-6-consultant-workspace"

    assert SeedStore.slugify("/home/x/resume-test__9c62d00f") == "-home-x-resume-test--9c62d00f"
  end

  test "read_map : workflow_map + jsonl présents → {:ok, uuid}, sinon :none", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det")

    # read_map relit l'uuid de la workflow_map = le builder stocké, PAS l'uuid du jsonl vivant ("u1").
    assert {:ok, %{uuid: "builder-det"}} = SeedStore.read_map("p", "engineer")
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

  # ============================================================
  # Confinement E (WI-E1) — un nom de projet/rôle non-slug ne traverse JAMAIS le seed-store.
  # ============================================================

  test "checkpoint : projet traversant (../evil) → REFUSÉ, rien écrit hors store", %{
    tmp: tmp,
    root: root
  } do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")

    # Cible d'évasion : `<root>/../evil/pods/...` = un dossier SŒUR de la racine seed-store.
    evil_dir = Path.expand(Path.join(root, "../evil"))

    assert {:error, _} = SeedStore.checkpoint(pod_dir, "../evil", "engineer", "builder-det")

    # Régression prouvée : sans la garde slug+confinement, `Path.join([root, "../evil", "pods"])`
    # écrirait `engineer.jsonl` ICI, hors de la racine. La garde le rend irreprésentable.
    refute File.exists?(evil_dir)
    refute File.exists?(Path.join([root, "..", "evil"]))
  end

  test "checkpoint : rôle traversant (a/b) → REFUSÉ", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "p", "a/b", "builder-det")
  end

  test "checkpoint : noms vides / NUL / contrôle → REFUSÉS", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "", "engineer", "builder-det")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "ok\x00evil", "engineer", "builder-det")
    assert {:error, _} = SeedStore.checkpoint(pod_dir, "ok\nevil", "engineer", "builder-det")
  end

  test "checkpoint : nom valide (my_checkpoint-1) → accepté", %{tmp: tmp, root: root} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "my_checkpoint-1", "engineer", "builder-det")
    assert File.exists?(Path.join([root, "my_checkpoint-1", "pods", "engineer.jsonl"]))
  end

  test "read_map : projet traversant → :none (ne lit pas hors store)", %{tmp: tmp} do
    pod_dir = Path.join(tmp, "pod")
    make_jsonl(pod_dir, "slug", "u1", "x\n")
    assert :ok = SeedStore.checkpoint(pod_dir, "p", "engineer", "builder-det")
    assert :none = SeedStore.read_map("../p", "engineer")
    assert :none = SeedStore.read_map("p", "../engineer")
  end

  test "restore : uuid évadant le pod_dir → REFUSÉ (raise fail-loud), aucune écriture hors pod",
       %{
         tmp: tmp
       } do
    seed = Path.join(tmp, "seed.jsonl")
    File.write!(seed, "mem\n")
    pod_dir = Path.join(tmp, "recallpod")

    # uuid hostile (lu d'un seed-map corrompu) : la feuille d'écriture est `pod_dir/.claude/projects/
    # <slug>/` (3 niveaux sous le pod) → il faut 4 `../` pour franchir le pod_dir et viser un fichier hôte
    # (`tmp/escaped.jsonl`). `restore` confine `dest` sous `pod_dir` via `under_root?` AVANT le `cp!` :
    # une évasion DOIT lever (le caller rabat le raise sur transition_failed, le pod ne lance pas). Un uuid
    # qui reste sous le pod (ex. `../../x` → `.claude/x.jsonl`) est légitime — le pod est éphémère et possédé ;
    # le seul vrai vecteur fermé ici est l'écriture HORS du pod.
    escape_target = Path.expand(Path.join(tmp, "escaped.jsonl"))
    File.rm(escape_target)

    assert_raise ArgumentError, fn ->
      SeedStore.restore(seed, pod_dir, "/home/r/recallpod", "../../../../escaped")
    end

    refute File.exists?(escape_target)
  end
end
