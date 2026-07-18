defmodule Fleet.Workflow.LoaderV25Test do
  @moduledoc """
  Loader — V2.5 pipeline envelope (`kind/metadata/spec`), the only accepted form.

  `Loader.load!` NORMALIZES the result to the single internal form
  `%{"name", "steps"}`: the v2.5 envelope is unwrapped at load (tests assert
  the normalized form, not the raw YAML), then the `workflow-map-v2.5.json`
  schema validates the structure (fail-loud).

  `async: true`: `:workflow_maps_root` is passed via opts to `Loader.load!/2`
  (no coupling to the global Application env).
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Loader

  # R0.8-brick6: canon pipelines reabsorbed in-repo.
  @canon_pipelines Application.app_dir(:lcars_fleet, "priv/workflow/canon/workflow_maps")

  test "canon standard-qa.yaml (V2.5) normalized → name + steps top-level" do
    pipe = Loader.load!("standard-qa", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "standard-qa"
    assert is_map(pipe["steps"])
    assert is_map(pipe["steps"]["brainstorm"])
    refute Map.has_key?(pipe, "spec")
  end

  test "canon audit-only.yaml (V2.5) normalized → name + steps top-level" do
    pipe = Loader.load!("audit-only", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "audit-only"
    assert is_map(pipe["steps"])
    refute Map.has_key?(pipe, "spec")
  end

  # F-C160: brief-gate IS the DEFAULT workflow_map of the prod dispatch (StepDispatcher) → it must be
  # covered by canon conformance like standard-qa + audit-only: it must normalize cleanly + carry its
  # load-bearing shape (consultant-judge brief gate BEFORE the engineer).
  test "canon brief-gate.yaml (V2.5, prod DEFAULT map) normalized → brief-review(judge) gate build" do
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
  test "V2.5 step with post_extract.git passes schema (face 2 of the git architecture decision)",
       %{tmp_dir: dir} do
    yaml = """
    kind: WorkflowMap
    metadata:
      name: face2-step
    spec:
      max_rework_rounds: 1
      jury: []
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
  test "V2.5 post_extract.git without repo_url nor branch → invalid", %{tmp_dir: dir} do
    yaml = """
    kind: WorkflowMap
    metadata:
      name: face2-missing-required
    spec:
      max_rework_rounds: 1
      jury: []
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
  test "V2.5 needs with a DUPLICATE → SCHEMA rejection (no lying :fan_out diagnostic)", %{
    tmp_dir: dir
  } do
    # `needs: [a, a]` (copy-paste) would pass the schema, the edge got laid TWICE, and the
    # GraphValidator rejected as :fan_out with a WRONG diagnostic ("2 successors [b, b]" on a
    # linear chain): fail-closed but a lying trace — the map author would hunt a nonexistent
    # fan-out. The rejection lives UPSTREAM (uniqueItems), with the true reason.
    yaml = """
    kind: WorkflowMap
    metadata:
      name: dup-needs
    spec:
      max_rework_rounds: 1
      jury: []
      steps:
        a:
          role: engineer
          profile: engineer
        b:
          role: engineer
          profile: engineer
          needs: ["a", "a"]
    """

    File.write!(Path.join(dir, "dup-needs.yaml"), yaml)

    assert_raise RuntimeError, ~r/workflow-map-v2\.5\.json invalid/, fn ->
      Loader.load!("dup-needs", workflow_maps_root: dir)
    end
  end

  @tag :tmp_dir
  test "structurally invalid V2.5 → raise schema workflow-map-v2.5", %{tmp_dir: dir} do
    bad = """
    kind: WorkflowMap
    metadata:
      name: bad
    spec:
      max_rework_rounds: 1
      jury: []
      steps: {}
    """

    File.write!(Path.join(dir, "bad.yaml"), bad)

    assert_raise RuntimeError, ~r/workflow-map-v2\.5\.json invalid/, fn ->
      Loader.load!("bad", workflow_maps_root: dir)
    end
  end

  @tag :tmp_dir
  test "soft-default #4 — hard gate with EMPTY rules → raise schema (enforcing nothing = fail-open)",
       %{
         tmp_dir: dir
       } do
    # Upstream lock: a hard-gate with empty rules would pass `Enum.all?([]) == true` → :pass (a gate
    # enforcing NOTHING). The schema REJECTS it at load (`if type==hard then rules minItems 1`) → the
    # case is unrepresentable upstream. (terminal keeps legitimate empty rules: the `finish` gate.)
    bad = """
    kind: WorkflowMap
    metadata:
      name: empty-hard
    spec:
      max_rework_rounds: 1
      jury: []
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
      jury: []
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
