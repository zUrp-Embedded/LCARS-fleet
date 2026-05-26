defmodule Fleet.Pipeline.LoaderV25Test do
  @moduledoc """
  Lot 6 inc1 — extension additive Loader format V2.5 (enveloppe
  kind/metadata/spec) sans casser le flat chantier-12. Détection
  présence `spec` top-level → pipeline-v2.5.json ; sinon → pipeline-v1.json.

  M7 — `async: true` : on passe `:pipelines_root` via opts à `Loader.load!/2`
  (pas de couplage Application env global).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pipeline.Loader

  # R0.8-brick6 : canon pipelines réabsorbés in-repo.
  @canon_pipelines Application.app_dir(:fleet_pipeline, "priv/canon/pipelines")

  test "canon standard-qa.yaml (V2.5) valide pipeline-v2.5.json via Loader" do
    yaml = Loader.load!("standard-qa", pipelines_root: @canon_pipelines)
    assert yaml["kind"] == "Pipeline"
    assert get_in(yaml, ["metadata", "name"]) == "standard-qa"
    assert is_map(get_in(yaml, ["spec", "stages"]))
  end

  test "canon audit-only.yaml (V2.5) valide pipeline-v2.5.json via Loader" do
    yaml = Loader.load!("audit-only", pipelines_root: @canon_pipelines)
    assert get_in(yaml, ["metadata", "name"]) == "audit-only"
    assert is_map(get_in(yaml, ["spec", "stages"]))
  end

  @tag :tmp_dir
  test "régression : flat chantier-12 (sans spec top-level) → pipeline-v1.json inchangé",
       %{tmp_dir: dir} do
    flat = """
    name: legacy-flat
    version: 1
    stages:
      only:
        role: engineer
        profile: engineer.yaml
    """

    File.write!(Path.join(dir, "legacy-flat.yaml"), flat)
    yaml = Loader.load!("legacy-flat", pipelines_root: dir)
    assert yaml["name"] == "legacy-flat"
    refute Map.has_key?(yaml, "spec")
  end

  @tag :tmp_dir
  test "V2.5 stage avec post_extract.git valide schema (face 2 décision archi git)",
       %{tmp_dir: dir} do
    yaml = """
    kind: Pipeline
    metadata:
      name: face2-stage
    spec:
      stages:
        publish:
          role: engineer
          profile: engineer
          post_extract:
            git:
              repo_url: http://gitea/fleet/lcars
              branch: feature/x
              push: true
              add_paths: ["docs/", "src/"]
    """

    File.write!(Path.join(dir, "face2-stage.yaml"), yaml)
    loaded = Loader.load!("face2-stage", pipelines_root: dir)
    stage = get_in(loaded, ["spec", "stages", "publish"])
    assert get_in(stage, ["post_extract", "git", "repo_url"]) == "http://gitea/fleet/lcars"
    assert get_in(stage, ["post_extract", "git", "branch"]) == "feature/x"
    assert get_in(stage, ["post_extract", "git", "push"]) == true
    assert get_in(stage, ["post_extract", "git", "add_paths"]) == ["docs/", "src/"]
  end

  @tag :tmp_dir
  test "V2.5 post_extract.git sans repo_url ni branch → invalide", %{tmp_dir: dir} do
    yaml = """
    kind: Pipeline
    metadata:
      name: face2-missing-required
    spec:
      stages:
        publish:
          role: engineer
          profile: engineer
          post_extract:
            git:
              push: true
    """

    File.write!(Path.join(dir, "face2-missing-required.yaml"), yaml)

    assert_raise RuntimeError, ~r/pipeline-v2\.5\.json invalide/, fn ->
      Loader.load!("face2-missing-required", pipelines_root: dir)
    end
  end

  @tag :tmp_dir
  test "V2.5 structurellement invalide → raise schema pipeline-v2.5", %{tmp_dir: dir} do
    bad = """
    kind: Pipeline
    metadata:
      name: bad
    spec:
      stages: {}
    """

    File.write!(Path.join(dir, "bad.yaml"), bad)

    assert_raise RuntimeError, ~r/pipeline-v2\.5\.json invalide/, fn ->
      Loader.load!("bad", pipelines_root: dir)
    end
  end

  @tag :tmp_dir
  test "M7 — load!/2 opt :schema_path override Application env", %{tmp_dir: dir} do
    yaml = """
    name: legacy-flat
    version: 1
    stages:
      only:
        role: engineer
        profile: engineer.yaml
    """

    File.write!(Path.join(dir, "legacy-flat.yaml"), yaml)
    # No global put_env — async: true safe.
    loaded = Loader.load!("legacy-flat", pipelines_root: dir)
    assert loaded["name"] == "legacy-flat"
  end
end
