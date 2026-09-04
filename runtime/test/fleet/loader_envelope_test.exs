defmodule Fleet.Workflow.LoaderEnvelopeTest do
  @moduledoc """
  Loader — the pipeline envelope (`kind/metadata/spec`), the only accepted form.

  `Loader.load!` NORMALIZES the result to the single internal form
  `%{"name", "steps"}`: the envelope is unwrapped at load (tests assert
  the normalized form, not the raw YAML), then the `workflow-map.json`
  schema validates the structure (fail-loud).

  `async: true`: `:workflow_maps_root` is passed via opts to `Loader.load!/2`
  (no coupling to the global Application env).
  """
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Loader

  # R0.8-brick6: canon pipelines reabsorbed in-repo.
  @canon_pipelines Application.app_dir(
                     :lcars_fleet,
                     "priv/catalogue/workflow/workflow_maps"
                   )

  test "canon standard-qa.yaml normalized → DISPATCHABLE steps only (brief-review gate + build)" do
    # rev3 rehabilitation: the old architect/starfleet steps were NOT servable by the
    # dispatch (live runaway 2026-07-18) — the card now carries only what the engine runs.
    pipe = Loader.load!("standard-qa", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "standard-qa"
    assert is_map(pipe["steps"]["brief-review"])
    assert pipe["steps"]["brief-review"]["role"] == "scoper"
    # The step no longer OVERRIDES `brief_kind`: `scoper` is a native judge since the 2026-07-30
    # split, and its profile carries the property. What must hold is the RESOLVED judge-ness, which
    # `Fleet.CapProfile` answers — asserting the map field would pin the mechanism, not the contract
    # (and pinning it is what hid the missing fallback in GateEngine until now).
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

  # F-C160: brief-gate IS the DEFAULT workflow_map of the prod dispatch (StepDispatcher) → it must be
  # covered by canon conformance like standard-qa + audit-only: it must normalize cleanly + carry its
  # load-bearing shape (scoper brief gate BEFORE the engineer).
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

  # The two production TYPE cards of the criticality catalogue: the card IS the judgment-layer
  # choice — the engine reads `jury` as data (`Roles.project_jury`), never hardcodes a panel.
  test "canon c0-poc.yaml normalized → single build step + DELIBERATE zero-judge jury" do
    pipe = Loader.load!("c0-poc", workflow_maps_root: @canon_pipelines)
    assert pipe["name"] == "c0-poc"
    assert pipe["jury"] == []
    assert Map.keys(pipe["steps"]) == ["build"]
    assert pipe["steps"]["build"]["role"] == "engineer"
    # The card's short description travels through normalize: it is the SSoT of the
    # `wfmap/<map>` forge-label tooltip (the card explains itself to the human).
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
    # THE SEAM WHERE THE DEFECT LIVED. `CiGate` was tested, the schema validated `spec.ci`
    # (enum required|ignore), three canon cards declared `required` — and the WIRE between them was
    # tested by nobody. `normalize/1` built a map without the key, so `Map.get(map, "ci")` in
    # `ReviewLifecycle.issue_card_ci/2` always answered nil, hence `:ignore`. The gate, its bounded
    # wait, its escalation and the fact it hands to the judge all existed and were unreachable, and
    # no card was distinguishable from a card declaring nothing.
    for name <- ~w(standard-qa brief-gate c1-light) do
      map = Loader.load!(name, workflow_maps_root: @canon_pipelines)

      assert Map.get(map, "ci") == "required",
             "#{name} declares `ci: required`; if it does not survive the loader the CI gate is " <>
               "disarmed on it, silently"
    end

    # And the card that does NOT gate says so, in the same words: `ignore` is a declaration, not an
    # absence. The distinction this line pins is the whole point of the mandatory field — before it,
    # this assertion read `== nil` and could not tell "decided against" from "forgot".
    audit = Loader.load!("audit-only", workflow_maps_root: @canon_pipelines)
    assert Map.get(audit, "ci") == "ignore"
  end

  test "NO canon card is silent on ci — the choice is written on every one of them" do
    # The catalogue-wide half of the property. The twin below proves declared == normalized, which
    # a catalogue of eight silent cards would satisfy perfectly (nil == nil, eight times): it
    # measures the WIRE, not the DECLARATION, and on its own it green-lights a catalogue where
    # nobody ever chose. This one measures the declaration.
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
    # THE MUTATION TARGET. Drop `"ci"` from `spec.required` in workflow-map.json and this test
    # is the one that goes red. Without it, the mandatory field is enforced only by the canon cards
    # happening to carry it — which is a convention, not a wall, and conventions do not survive the
    # next card someone writes in a hurry.
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
    # Generic twin of the test above: it does not name the three cards, so a FOURTH card declaring
    # `ci` is covered the day it lands rather than the day someone remembers to add it here.
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
    # Le mur, et il tient en une phrase : ce qu'un auteur de carte lit sur un champ doit correspondre
    # a ce que le moteur en fait. Un champ sans lecteur qui ne le dit pas se lit comme un contrat ;
    # un champ QUI A un lecteur et qui se declare documentaire est pire — il invite a le remplir a
    # cote de la verification qui le lit vraiment.
    #
    # La paire est asymetrique depuis BL-6-59, et l'asymetrie est le point : `outputs` est verifiable
    # dans le workspace du pod, `inputs` ne l'est pas (une source peut etre un ticket, une autre
    # face, un depot distant).
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

    # `outputs` : le lecteur est PROUVE ici, pas cite. On l'exerce — un champ declare produit des
    # faits, un champ absent n'en produit aucun. Une assertion sur le seul texte du schema serait
    # une seconde liste a tenir a la main, exactement ce que ce test existe pour eviter.
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
    # `decisions` was declared by the schema and had neither a producer nor a consumer: no canon
    # card posed it, no line of `lib/` read it. A schema property that connects nothing to nothing
    # invites a card author to declare something that does nothing, and the card validates — which
    # is the most expensive kind of silence, because it looks like it worked.
    #
    # Removed. `additionalProperties: false` then does the rest: the key is now REFUSED with the
    # schema's own reason instead of being carried into a void.
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
    # No global put_env — async: true safe.
    loaded = Loader.load!("override-target", workflow_maps_root: dir)
    assert loaded["name"] == "override-target"
  end

  @tag :tmp_dir
  test "a SUBSTITUTED schema cannot smuggle a nil ci through normalisation", %{tmp_dir: dir} do
    # THE SECOND LOCK, and it exists because the first one is bypassable. `spec.ci` being mandatory
    # is enforced by the schema — and `:schema_path` is an opt: any caller may hand the loader a
    # laxer contract. Past that door, `normalize/1` is the last reader, and a `Map.get` there would
    # hand back `"ci" => nil` — a policy nobody declared, rebuilt one layer below the wall that was
    # supposed to make it unrepresentable. `Map.fetch!` turns that into a crash naming the key.
    #
    # Mutation-checked: with `fetch!` swapped for `get`, the whole suite stayed green without this
    # test — every card in the tree declares `ci`, so the two are indistinguishable on the nominal
    # path. A guard whose removal changes nothing is not a guard.
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
