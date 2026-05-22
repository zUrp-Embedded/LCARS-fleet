defmodule Fleet.Pipeline.LoaderV25Test do
  @moduledoc """
  Lot 6 inc1 — extension additive Loader format V2.5 (enveloppe
  apiVersion/kind/metadata/spec) sans casser le flat chantier-12.
  Détection `apiVersion` → pipeline-v2.5.json ; sinon → pipeline-v1.json.
  `async: false` (Application env :pipelines_root global).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pipeline.Loader

  # __DIR__ = .../runtime-v2/apps/fleet_pipeline/test/fleet → 6 remontées → beyond_#4
  @canon_pipelines Path.join([
                     __DIR__,
                     "..",
                     "..",
                     "..",
                     "..",
                     "..",
                     "..",
                     "06_modops",
                     "pipelines"
                   ])

  setup do
    prev = Application.get_env(:fleet_pipeline, :pipelines_root)
    prev_schema = Application.get_env(:fleet_pipeline, :schema_path)
    # IMPORTANT : ne PAS fixer :schema_path (sinon override la détection format).
    Application.delete_env(:fleet_pipeline, :schema_path)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_pipeline, :pipelines_root, prev),
        else: Application.delete_env(:fleet_pipeline, :pipelines_root)

      if prev_schema, do: Application.put_env(:fleet_pipeline, :schema_path, prev_schema)
    end)

    :ok
  end

  test "canon standard-qa.yaml (V2.5) valide pipeline-v2.5.json via Loader" do
    Application.put_env(:fleet_pipeline, :pipelines_root, @canon_pipelines)
    yaml = Loader.load!("standard-qa")
    assert yaml["apiVersion"] == "lcars/v2.5"
    assert yaml["kind"] == "Pipeline"
    assert get_in(yaml, ["metadata", "name"]) == "standard-qa"
    assert is_map(get_in(yaml, ["spec", "stages"]))
  end

  test "canon audit-only.yaml (V2.5) valide pipeline-v2.5.json via Loader" do
    Application.put_env(:fleet_pipeline, :pipelines_root, @canon_pipelines)
    yaml = Loader.load!("audit-only")
    assert yaml["apiVersion"] == "lcars/v2.5"
    assert get_in(yaml, ["metadata", "name"]) == "audit-only"
  end

  @tag :tmp_dir
  test "régression : flat chantier-12 (sans apiVersion) → pipeline-v1.json inchangé",
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
    Application.put_env(:fleet_pipeline, :pipelines_root, dir)
    yaml = Loader.load!("legacy-flat")
    assert yaml["name"] == "legacy-flat"
    refute Map.has_key?(yaml, "apiVersion")
  end

  @tag :tmp_dir
  test "V2.5 structurellement invalide → raise schema pipeline-v2.5", %{tmp_dir: dir} do
    bad = """
    apiVersion: lcars/v2.5
    kind: Pipeline
    metadata:
      name: bad
    spec:
      stages: {}
    """

    File.write!(Path.join(dir, "bad.yaml"), bad)
    Application.put_env(:fleet_pipeline, :pipelines_root, dir)

    assert_raise RuntimeError, ~r/pipeline-v2\.5\.json invalide/, fn ->
      Loader.load!("bad")
    end
  end
end
