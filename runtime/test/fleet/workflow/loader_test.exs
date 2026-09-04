defmodule Fleet.Workflow.LoaderTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.Workflow.Loader

  setup %{tmp_dir: tmp_dir} do
    # `put_env_restoring` ET PAS `put_env` + `delete_env` : la clef EST posee ailleurs
    # (`config/runtime.exs:581`, depuis `LCARS_WORKFLOW_MAPS_ROOT`), donc l'ancien couple ne
    # restaurait pas — il SUPPRIMAIT, et laissait derriere lui un ambiant que ce fichier n'avait pas
    # trouve. `restore_env_on_exit` capture par `fetch_env` : absente elle est re-supprimee, posee
    # elle est re-posee telle quelle.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :workflow_workflow_maps_root, tmp_dir)
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
        ci: ignore
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
        ci: ignore
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
        ci: ignore
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
        ci: ignore
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
        ci: ignore
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
        ci: ignore
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
        ci: ignore
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

  describe "canon_names!/1 — guard enumeration" do
    # `Path.wildcard` flattens a missing root and an empty catalogue into the same `[]`,
    # which makes every "for each canon card" guard vacuously true. The bang form keeps
    # the three states distinct; these tests pin each one.
    test "missing root → raise naming the root and its config sources", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "nowhere")

      assert_raise RuntimeError, ~r/does not exist/, fn ->
        Loader.canon_names!(workflow_maps_root: missing)
      end
    end

    test "empty catalogue → raise naming the vacuous-truth consequence", %{tmp_dir: tmp_dir} do
      assert_raise RuntimeError, ~r/no \*\.yaml card/, fn ->
        Loader.canon_names!(workflow_maps_root: tmp_dir)
      end
    end

    test "populated catalogue → the same names as canon_names/1", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "one.yaml"), "kind: WorkflowMap\n")

      assert Loader.canon_names!(workflow_maps_root: tmp_dir) == ["one"]
      assert Loader.canon_names(workflow_maps_root: tmp_dir) == ["one"]
    end
  end

  describe "published image — what the boot proved IS what runs" do
    setup do
      on_exit(fn -> Loader.unpublish_all_images() end)
      :ok
    end

    defp write_card(dir, name) do
      File.write!(Path.join(dir, "#{name}.yaml"), """
      kind: WorkflowMap
      metadata:
        name: #{name}
      spec:
        max_rework_rounds: 1
        jury: []
        ci: ignore
        steps:
          only:
            role: noop
      """)
    end

    test "no-opts readers serve the image — a post-boot disk edit is INERT", %{tmp_dir: tmp} do
      write_card(tmp, "steady")
      assert :ok = Loader.publish_image!()

      # Post-publish mutations of the live catalogue: one card rewritten, one added.
      File.write!(Path.join(tmp, "steady.yaml"), """
      kind: WorkflowMap
      metadata:
        name: steady
      spec:
        max_rework_rounds: 9
        jury: [qualifier]
        ci: ignore
        steps:
          a:
            role: noop
          b:
            role: noop
            needs: [a]
      """)

      write_card(tmp, "late")

      # The image, not the disk: the proven single-step card, the proven enumeration.
      assert %{"max_rework_rounds" => 1, "steps" => steps} = Loader.load!("steady")
      assert map_size(steps) == 1
      assert Loader.canon_names() == ["steady"]
      assert Loader.canon_names!() == ["steady"]

      # A card that exists on disk but not in the image is refused BY NAME (never a
      # silent half-epoch mixing proven and unproven cards).
      assert_raise RuntimeError, ~r/not in the published catalogue image/, fn ->
        Loader.load!("late")
      end
    end

    test "explicit opts stay a direct disk read (the hermetic path bypasses the image)", %{
      tmp_dir: tmp
    } do
      write_card(tmp, "steady")
      assert :ok = Loader.publish_image!()
      write_card(tmp, "late")

      assert %{"name" => "late"} = Loader.load!("late", workflow_maps_root: tmp)
      assert Loader.canon_names(workflow_maps_root: tmp) == ["late", "steady"]
    end

    test "publish is all-or-nothing: one invalid card → raise, NOTHING published", %{
      tmp_dir: tmp
    } do
      write_card(tmp, "steady")

      File.write!(
        Path.join(tmp, "broken.yaml"),
        "kind: WorkflowMap\nmetadata:\n  name: broken\nspec: {}\n"
      )

      assert_raise RuntimeError, ~r/schema .*invalid/, fn -> Loader.publish_image!() end

      # No image → the readers still enumerate the DISK (both cards visible): the failed
      # publish left no partial epoch behind.
      assert Loader.canon_names() == ["broken", "steady"]
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
        ci: ignore
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
      canon_dir = Application.app_dir(:lcars_fleet, "priv/catalogue/workflow/workflow_maps")

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
