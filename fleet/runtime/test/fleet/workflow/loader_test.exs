defmodule Fleet.Workflow.LoaderTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.Workflow.Loader

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_workflow, :workflow_maps_root, tmp_dir)

    on_exit(fn ->
      Application.delete_env(:fleet_workflow, :workflow_maps_root)
    end)

    :ok
  end

  describe "load!/1" do
    test "minimal valid pipeline → map", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "minimal.yaml"), """
      kind: WorkflowMap
      metadata:
        name: minimal
      spec:
        max_rework_rounds: 1
        jury: []
        steps:
          only:
            role: noop
      """)

      # Normalized shape `%{"name", "steps"}`: the envelope (kind/metadata/spec)
      # is unwrapped at load; only `name` (from metadata) and `steps` survive.
      assert %{"name" => "minimal", "steps" => %{"only" => _}} =
               Loader.load!("minimal")
    end

    test "invalid schema (missing steps field) → raise", %{tmp_dir: tmp_dir} do
      # Valid v2.5 envelope but `spec.steps` absent → `spec` requires `steps`.
      File.write!(Path.join(tmp_dir, "invalid.yaml"), """
      kind: WorkflowMap
      metadata:
        name: invalid
      spec: {}
      """)

      assert_raise RuntimeError, ~r/schema .*invalid/, fn ->
        Loader.load!("invalid")
      end
    end

    test "invalid schema (unsupported gate type) → raise", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "bad_gate.yaml"), """
      kind: WorkflowMap
      metadata:
        name: bad_gate
      spec:
        max_rework_rounds: 1
        jury: []
        steps:
          s1:
            role: noop
            gate:
              type: hocus_pocus
      """)

      assert_raise RuntimeError, ~r/schema .*invalid/, fn ->
        Loader.load!("bad_gate")
      end
    end

    test "file not found → YamlElixir.FileNotFoundError", %{tmp_dir: _tmp_dir} do
      assert_raise YamlElixir.FileNotFoundError, fn ->
        Loader.load!("nonexistent")
      end
    end

    # Containment (WI-E3): a non-slug workflow_map/pipeline name NEVER traverses the root.
    test "traversing pipeline name (../) → REFUSED before Path.join", %{tmp_dir: tmp_dir} do
      # Plants an escape target: `<root>/../escape.yaml`.
      File.write!(Path.join([tmp_dir, "..", "escape.yaml"]), """
      kind: WorkflowMap
      metadata:
        name: escape
      spec:
        max_rework_rounds: 1
        jury: []
        steps:
          only:
            role: noop
      """)

      # Without the slug guard, `Path.join(root, "../escape.yaml")` would read this out-of-catalog YAML.
      # `cast!` raises BEFORE the Path.join.
      assert_raise ArgumentError, ~r/invalid slug/, fn ->
        Loader.load!("../escape")
      end

      File.rm(Path.join([tmp_dir, "..", "escape.yaml"]))
    end

    test "pipeline name with a slash → REFUSED", %{tmp_dir: _tmp_dir} do
      assert_raise ArgumentError, ~r/invalid slug/, fn ->
        Loader.load!("a/b")
      end
    end

    test "step with needs + inputs + valid hard gate", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "complex.yaml"), """
      kind: WorkflowMap
      metadata:
        name: complex
      spec:
        max_rework_rounds: 1
        jury: []
        steps:
          a:
            role: scout
            outputs:
              - result_id
          b:
            role: archivist
            needs: [a]
            inputs:
              - result_id
            gate:
              type: hard
              rules:
                - all_tests_pass
      """)

      assert %{"steps" => %{"a" => _, "b" => step_b}} = Loader.load!("complex")
      assert step_b["needs"] == ["a"]
      assert step_b["gate"]["type"] == "hard"
    end

    test "valid brief_kind/judge_target/timeout_sec → load OK", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "typed.yaml"), """
      kind: WorkflowMap
      metadata:
        name: typed
      spec:
        max_rework_rounds: 1
        jury: []
        steps:
          review:
            role: reviewer
            brief_kind: judge
            judge_target: brief
      """)

      assert %{"steps" => %{"review" => step}} = Loader.load!("typed")
      assert step["brief_kind"] == "judge"
      assert step["judge_target"] == "brief"
    end

    # SECURITY property (boundary): a brief_kind outside {worker, judge} is rejected at LOAD
    # (fail-closed at the boundary). It can NEVER reach the dispatcher to be inferred as
    # worker there (executable brief for a role that should have been defused).
    test "out-of-vocab brief_kind → rejected at load (raise)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "bad_kind.yaml"), """
      kind: WorkflowMap
      metadata:
        name: bad_kind
      spec:
        max_rework_rounds: 1
        jury: []
        steps:
          review:
            role: reviewer
            brief_kind: reviewer
      """)

      assert_raise RuntimeError, ~r/schema .*invalid/, fn ->
        Loader.load!("bad_kind")
      end
    end

    # additionalProperties:false — an unknown step field is rejected at load (anti-typo /
    # anti-phantom-field) instead of being silently ignored.
    test "unknown step field → rejected at load (raise)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "unknown_field.yaml"), """
      kind: WorkflowMap
      metadata:
        name: unknown_field
      spec:
        max_rework_rounds: 1
        jury: []
        steps:
          s:
            role: noop
            bogus_field: oops
      """)

      assert_raise RuntimeError, ~r/schema .*invalid/, fn ->
        Loader.load!("unknown_field")
      end
    end
  end

  describe "load!/2 — graph validation" do
    # Schema-VALID (needs = array of strings) but graph-INVALID: `b` refers to a nonexistent
    # step. The schema lets it through (inter-step constraint inexpressible in draft-07);
    # the graph linter raises at load — otherwise silent phantom edge → frozen pipeline.
    test "workflow_map with a phantom needs (passes the schema) → graph linter raise", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "phantom.yaml"), """
      kind: WorkflowMap
      metadata:
        name: phantom
      spec:
        max_rework_rounds: 1
        jury: []
        steps:
          a:
            role: noop
          b:
            role: noop
            needs: [typo]
      """)

      assert_raise RuntimeError, ~r/phantom edge/, fn ->
        Loader.load!("phantom")
      end
    end

    # Anti-regression guard: every canon workflow_map must pass the graph linter.
    # A canon workflow_map failing here = either a real workflow_map bug, or an invariant too strict.
    test "all canon workflow_maps pass the linter" do
      canon_dir = Application.app_dir(:lcars_fleet, "priv/workflow/canon/workflow_maps")

      names =
        canon_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.map(&Path.basename(&1, ".yaml"))

      refute names == [], "no canon workflow_map found in #{canon_dir}"

      for name <- names do
        assert %{"name" => _, "steps" => _} = Loader.load!(name, workflow_maps_root: canon_dir)
      end
    end
  end
end
