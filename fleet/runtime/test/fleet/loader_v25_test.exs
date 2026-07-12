defmodule Fleet.Workflow.LoaderV25Test do
  @moduledoc """
  Loader — enveloppe pipeline V2.5 (`kind/metadata/spec`), seule forme acceptée.

  `Loader.load!` NORMALISE le résultat vers la forme interne unique
  `%{"name", "steps"}` : l'enveloppe v2.5 est déballée au load (les tests
  assertent la forme normalisée, pas le YAML brut), puis le schema
  `workflow-map-v2.5.json` valide la structure (fail-loud).

  `async: true` : on passe `:workflow_maps_root` via opts à `Loader.load!/2`
  (pas de couplage Application env global).
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Loader

  # R0.8-brick6 : canon pipelines réabsorbés in-repo.
  @canon_pipelines Application.app_dir(:fleet_workflow, "priv/canon/workflow_maps")

  test "canon standard-qa.yaml (V2.5) normalisé → name + steps top-level" do
    pipe = Loader.load!("standard-qa", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "standard-qa"
    assert is_map(pipe["steps"])
    assert is_map(pipe["steps"]["brainstorm"])
    refute Map.has_key?(pipe, "spec")
  end

  test "canon audit-only.yaml (V2.5) normalisé → name + steps top-level" do
    pipe = Loader.load!("audit-only", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "audit-only"
    assert is_map(pipe["steps"])
    refute Map.has_key?(pipe, "spec")
  end

  # F-C160 : brief-gate EST la workflow_map DÉFAUT du dispatch prod (StepDispatcher) mais était exclue de
  # la conformance canon (seules standard-qa + audit-only étaient couvertes). On la couvre : elle doit
  # normaliser proprement + porter sa forme load-bearing (gate de brief consultant-juge AVANT l'engineer).
  test "canon brief-gate.yaml (V2.5, map DÉFAUT prod) normalisé → brief-review(judge) gate build" do
    pipe = Loader.load!("brief-gate", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "brief-gate"
    assert is_map(pipe["steps"])
    assert is_map(pipe["steps"]["brief-review"])
    assert pipe["steps"]["brief-review"]["brief_kind"] == "judge"
    assert is_map(pipe["steps"]["build"])
    assert pipe["steps"]["build"]["needs"] == ["brief-review"]
    refute Map.has_key?(pipe, "spec")
  end

  @tag :tmp_dir
  test "V2.5 step avec post_extract.git valide schema (face 2 décision archi git)",
       %{tmp_dir: dir} do
    yaml = """
    kind: WorkflowMap
    metadata:
      name: face2-step
    spec:
      max_rework_rounds: 1
      steps:
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

    File.write!(Path.join(dir, "face2-step.yaml"), yaml)
    loaded = Loader.load!("face2-step", workflow_maps_root: dir)
    step = get_in(loaded, ["steps", "publish"])
    assert get_in(step, ["post_extract", "git", "repo_url"]) == "http://gitea/fleet/lcars"
    assert get_in(step, ["post_extract", "git", "branch"]) == "feature/x"
    assert get_in(step, ["post_extract", "git", "push"]) == true
    assert get_in(step, ["post_extract", "git", "add_paths"]) == ["docs/", "src/"]
  end

  @tag :tmp_dir
  test "V2.5 post_extract.git sans repo_url ni branch → invalide", %{tmp_dir: dir} do
    yaml = """
    kind: WorkflowMap
    metadata:
      name: face2-missing-required
    spec:
      max_rework_rounds: 1
      steps:
        publish:
          role: engineer
          profile: engineer
          post_extract:
            git:
              push: true
    """

    File.write!(Path.join(dir, "face2-missing-required.yaml"), yaml)

    assert_raise RuntimeError, ~r/workflow-map-v2\.5\.json invalid/, fn ->
      Loader.load!("face2-missing-required", workflow_maps_root: dir)
    end
  end

  @tag :tmp_dir
  test "V2.5 structurellement invalide → raise schema workflow-map-v2.5", %{tmp_dir: dir} do
    bad = """
    kind: WorkflowMap
    metadata:
      name: bad
    spec:
      max_rework_rounds: 1
      steps: {}
    """

    File.write!(Path.join(dir, "bad.yaml"), bad)

    assert_raise RuntimeError, ~r/workflow-map-v2\.5\.json invalid/, fn ->
      Loader.load!("bad", workflow_maps_root: dir)
    end
  end

  @tag :tmp_dir
  test "soft-default #4 — hard gate avec rules VIDES → raise schema (n'applique rien = fail-open)",
       %{
         tmp_dir: dir
       } do
    # Verrou amont : une hard-gate à rules vides passait `Enum.all?([]) == true` → :pass (gate qui
    # n'applique RIEN). Le schéma la REJETTE au load (`if type==hard then rules minItems 1`) → le cas
    # est inreprésentable en amont. (terminal garde des rules vides légitimes : la gate `finish`.)
    bad = """
    kind: WorkflowMap
    metadata:
      name: empty-hard
    spec:
      max_rework_rounds: 1
      steps:
        build:
          role: engineer
          profile: engineer
          gate:
            type: hard
            rules: []
    """

    File.write!(Path.join(dir, "empty-hard.yaml"), bad)

    assert_raise RuntimeError, ~r/workflow-map-v2\.5\.json invalid/, fn ->
      Loader.load!("empty-hard", workflow_maps_root: dir)
    end
  end

  @tag :tmp_dir
  test "M7 — load!/2 opt :schema_path override Application env", %{tmp_dir: dir} do
    yaml = """
    kind: WorkflowMap
    metadata:
      name: override-target
    spec:
      max_rework_rounds: 1
      steps:
        only:
          role: engineer
          profile: engineer.yaml
    """

    File.write!(Path.join(dir, "override-target.yaml"), yaml)
    # No global put_env — async: true safe.
    loaded = Loader.load!("override-target", workflow_maps_root: dir)
    assert loaded["name"] == "override-target"
  end
end
