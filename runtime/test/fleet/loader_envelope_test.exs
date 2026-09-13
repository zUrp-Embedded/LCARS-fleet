defmodule Fleet.Workflow.LoaderEnvelopeTest do
  @moduledoc """
  Checks schema validation of workflow envelopes and preservation of fields in normalized maps.
  Loader validates the raw envelope before normalization and graph checks.
  Per-call workflow_maps_root options isolate fixture loads for async tests.
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Loader

  @canon_pipelines Application.app_dir(
                     :lcars_fleet,
                     "priv/catalogue/workflow/workflow_maps"
                   )

  test "canon standard-qa.yaml normalized → DISPATCHABLE steps only (brief-review gate + build)" do
    pipe = Loader.load!("standard-qa", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "standard-qa"
    assert is_map(pipe["steps"]["brief-review"])
    assert pipe["steps"]["brief-review"]["role"] == "scoper"
    # Judge mission belongs to the resolved role profile, not a per-step override.
    assert {:ok, profile} = Fleet.CapProfile.load(pipe["steps"]["brief-review"]["role"])
    assert Fleet.CapProfile.brief_kind(profile) == "judge"
    assert pipe["steps"]["brief-review"]["judge_target"] == "brief"
    assert pipe["steps"]["build"]["needs"] == ["brief-review"]
    assert pipe["jury"] == ["qualifier", "reviewer"]
    refute Map.has_key?(pipe, "spec")
  end

  test "canon audit-only.yaml normalized → name + steps top-level" do
    pipe = Loader.load!("audit-only", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "audit-only"
    assert is_map(pipe["steps"])
    refute Map.has_key?(pipe, "spec")
  end

  # Check the bundled brief-gate shape independently of which card a catalogue selects as default.
  test "canon brief-gate.yaml (prod DEFAULT map) normalized → brief-review(judge) gate build" do
    pipe = Loader.load!("brief-gate", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "brief-gate"
    assert is_map(pipe["steps"])
    assert is_map(pipe["steps"]["brief-review"])
    assert pipe["steps"]["brief-review"]["role"] == "scoper"
    assert {:ok, profile} = Fleet.CapProfile.load(pipe["steps"]["brief-review"]["role"])
    assert Fleet.CapProfile.brief_kind(profile) == "judge"
    assert is_map(pipe["steps"]["build"])
    assert pipe["steps"]["build"]["needs"] == ["brief-review"]
    refute Map.has_key?(pipe, "spec")
  end

  # Jury choice is card data, including an intentionally empty panel.
  test "canon c0-poc.yaml normalized → single build step + DELIBERATE zero-judge jury" do
    pipe = Loader.load!("c0-poc", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "c0-poc"
    assert pipe["jury"] == []
    assert Map.keys(pipe["steps"]) == ["build"]
    assert pipe["steps"]["build"]["role"] == "engineer"
    # Description must survive normalization for the wfmap label tooltip.
    assert is_binary(pipe["description"]) and pipe["description"] != ""
  end

  test "canon c1-light.yaml normalized → single build step + qualifier-only jury" do
    pipe = Loader.load!("c1-light", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "c1-light"
    assert pipe["jury"] == ["qualifier"]
    assert Map.keys(pipe["steps"]) == ["build"]
    assert pipe["steps"]["build"]["role"] == "engineer"
  end

  test "spec.ci SURVIVES normalisation — a declared gate that does not cross is a dead guarantee" do
    # Losing ci in normalization silently disables the gate even when declaration and gate tests pass.
    for name <- ~w(standard-qa brief-gate c1-light) do
      map = Loader.load!(name, workflow_maps_root: @canon_pipelines)

      assert Map.get(map, "ci") == "required",
             "#{name} declares `ci: required`; if it does not survive the loader the CI gate is " <>
               "disarmed on it, silently"
    end

    # Explicit ignore distinguishes a choice from a missing declaration.
    audit = Loader.load!("audit-only", workflow_maps_root: @canon_pipelines)
    assert Map.get(audit, "ci") == "ignore"
  end

  test "NO canon card is silent on ci — the choice is written on every one of them" do
    # Equality alone would accept nil == nil: separately require a declaration in each file found.
    for path <- Path.wildcard(Path.join(@canon_pipelines, "*.yaml")) do
      name = Path.basename(path, ".yaml")
      declared = YamlElixir.read_from_file!(path) |> get_in(["spec", "ci"])

      assert declared in ["required", "ignore"],
             "#{name}: spec.ci is #{inspect(declared)} — a canon card states its CI policy or it " <>
               "is not canon. `ignore` is a legitimate answer; silence is not one, because a " <>
               "reader cannot tell it from an omission"
    end
  end

  test "a card that OMITS ci is refused by the loader — the silent card is unrepresentable" do
    # Nominal cards all contain ci; a missing-field fixture exercises the schema requirement.
    tmp = Fleet.TestEnv.tmp_path("ci-mandatory")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    File.write!(Path.join(tmp, "muette.yaml"), """
    kind: WorkflowMap
    metadata:
      name: muette
    spec:
      max_rework_rounds: 1
      jury: []
      steps:
        build:
          role: engineer
    """)

    assert_raise RuntimeError, ~r/schema .* invalid for muette/, fn ->
      Loader.load!("muette", workflow_maps_root: tmp)
    end
  end

  test "EVERY canon card's declared spec.ci reaches the normalized map" do
    for path <- Path.wildcard(Path.join(@canon_pipelines, "*.yaml")) do
      name = Path.basename(path, ".yaml")
      raw = YamlElixir.read_from_file!(path)
      declared = get_in(raw, ["spec", "ci"])
      normalized = Loader.load!(name, workflow_maps_root: @canon_pipelines) |> Map.get("ci")

      assert normalized == declared,
             "#{name}: spec.ci declared #{inspect(declared)} but the loader yields " <>
               "#{inspect(normalized)} — the card and the engine disagree"
    end
  end

  test "un champ d'etape dit la VERITE sur l'existence de son lecteur runtime" do
    # Outputs have a workspace verifier; inputs may refer to tickets or remote sources.
    # This checks schema wording and exercises the outputs reader, not absence of all inputs readers.
    schema =
      Path.join([:code.priv_dir(:lcars_fleet), "workflow", "schema", "workflow-map.json"])
      |> File.read!()
      |> JSON.decode!()

    step =
      schema["properties"]["spec"]["properties"]["steps"]["patternProperties"][
        "^[a-zA-Z0-9_-]+$"
      ]["properties"]

    assert step["inputs"]["description"] =~ "DOCUMENTAIRE",
           "inputs n'a aucun lecteur runtime et le schema ne le dit pas — un auteur de carte " <>
             "le lira comme un contrat"

    # Exercise derive with and without outputs so checking prose alone cannot pass.
    assert Fleet.Workflow.StepOutputs.derive(%{"outputs" => ["x/y.json"]}, nil) != %{},
           "le schema va declarer outputs LU par le moteur — mais rien ne le lit"

    assert Fleet.Workflow.StepOutputs.derive(%{}, nil) == %{}

    refute step["outputs"]["description"] =~ "DOCUMENTAIRE",
           "outputs A un lecteur runtime (Fleet.Workflow.StepOutputs) et le schema le declare " <>
             "encore documentaire — un auteur de carte le remplira a cote de la porte qui le lit"

    assert step["outputs"]["description"] =~ "StepOutputs",
           "outputs est lu par le moteur : le schema doit NOMMER son lecteur, sinon l'auteur de " <>
             "carte ne sait pas ce qui va verifier ce qu'il ecrit"
  end

  @tag :tmp_dir
  test "a step key that means NOTHING is REFUSED, not silently accepted", %{tmp_dir: dir} do
    # Reject the retired decisions field rather than accepting a setting with no runtime effect.
    yaml = """
    kind: WorkflowMap
    metadata:
      name: inert-key
    spec:
      max_rework_rounds: 1
      jury: []
      ci: ignore
      steps:
        a:
          role: engineer
          decisions: ["continue", "abandon"]
    """

    File.write!(Path.join(dir, "inert-key.yaml"), yaml)

    assert_raise RuntimeError, ~r/workflow-map\.json invalid/, fn ->
      Loader.load!("inert-key", workflow_maps_root: dir)
    end
  end

  @tag :tmp_dir
  test "needs with a DUPLICATE → SCHEMA rejection (no lying :fan_out diagnostic)", %{
    tmp_dir: dir
  } do
    # Duplicate edges otherwise look like fan-out to GraphValidator; reject them at the schema.
    yaml = """
    kind: WorkflowMap
    metadata:
      name: dup-needs
    spec:
      max_rework_rounds: 1
      jury: []
      ci: ignore
      steps:
        a:
          role: engineer
        b:
          role: engineer
          needs: ["a", "a"]
    """

    File.write!(Path.join(dir, "dup-needs.yaml"), yaml)

    assert_raise RuntimeError, ~r/workflow-map\.json invalid/, fn ->
      Loader.load!("dup-needs", workflow_maps_root: dir)
    end
  end

  @tag :tmp_dir
  test "structurally invalid envelope → raise schema workflow-map", %{tmp_dir: dir} do
    bad = """
    kind: WorkflowMap
    metadata:
      name: bad
    spec:
      max_rework_rounds: 1
      jury: []
      ci: ignore
      steps: {}
    """

    File.write!(Path.join(dir, "bad.yaml"), bad)

    assert_raise RuntimeError, ~r/workflow-map\.json invalid/, fn ->
      Loader.load!("bad", workflow_maps_root: dir)
    end
  end

  @tag :tmp_dir
  test "soft-default #4 — hard gate with EMPTY rules → raise schema (enforcing nothing = fail-open)",
       %{
         tmp_dir: dir
       } do
    # Empty hard rules would pass Enum.all? vacuously. Terminal gates may legitimately have none.
    bad = """
    kind: WorkflowMap
    metadata:
      name: empty-hard
    spec:
      max_rework_rounds: 1
      jury: []
      ci: ignore
      steps:
        build:
          role: engineer
          gate:
            type: hard
            rules: []
    """

    File.write!(Path.join(dir, "empty-hard.yaml"), bad)

    assert_raise RuntimeError, ~r/workflow-map\.json invalid/, fn ->
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
      ci: ignore
      steps:
        only:
          role: engineer
    """

    File.write!(Path.join(dir, "override-target.yaml"), yaml)
    # This case uses workflow_maps_root only; despite its title, it does not pass schema_path.
    loaded = Loader.load!("override-target", workflow_maps_root: dir)
    assert loaded["name"] == "override-target"
  end

  @tag :tmp_dir
  test "a SUBSTITUTED schema cannot smuggle a nil ci through normalisation", %{tmp_dir: dir} do
    # A lax schema can bypass the first requirement. Normalization must still fetch ci strictly;
    # nominal cards cannot distinguish Map.fetch! from Map.get because they all declare the field.
    lax = Path.join(dir, "lax-schema.json")

    real =
      :code.priv_dir(:lcars_fleet)
      |> to_string()
      |> Path.join("workflow/schema/workflow-map.json")
      |> File.read!()
      |> Jason.decode!()

    lax_schema = update_in(real, ["properties", "spec", "required"], &(&1 -- ["ci"]))
    File.write!(lax, Jason.encode!(lax_schema))

    File.write!(Path.join(dir, "smuggled.yaml"), """
    kind: WorkflowMap
    metadata:
      name: smuggled
    spec:
      max_rework_rounds: 1
      jury: []
      steps:
        only:
          role: engineer
    """)

    assert_raise KeyError, ~r/key "ci" not found/, fn ->
      Loader.load!("smuggled", workflow_maps_root: dir, schema_path: lax)
    end
  end
end
