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
    test "pipeline minimal valide → map", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "minimal.yaml"), """
      kind: WorkflowMap
      metadata:
        name: minimal
      spec:
        max_rework_rounds: 1
        steps:
          only:
            role: noop
            profile: empty
      """)

      # Forme normalisée `%{"name", "steps"}` : l'enveloppe (kind/metadata/spec)
      # est déballée au load, seuls `name` (depuis metadata) et `steps` survivent.
      assert %{"name" => "minimal", "steps" => %{"only" => _}} =
               Loader.load!("minimal")
    end

    test "schema invalide (champ steps manquant) → raise", %{tmp_dir: tmp_dir} do
      # Enveloppe v2.5 valide mais `spec.steps` absent → `spec` exige `steps`.
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

    test "schema invalide (gate type non-supporté) → raise", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "bad_gate.yaml"), """
      kind: WorkflowMap
      metadata:
        name: bad_gate
      spec:
        max_rework_rounds: 1
        steps:
          s1:
            role: noop
            profile: empty
            gate:
              type: hocus_pocus
      """)

      assert_raise RuntimeError, ~r/schema .*invalid/, fn ->
        Loader.load!("bad_gate")
      end
    end

    test "fichier introuvable → YamlElixir.FileNotFoundError", %{tmp_dir: _tmp_dir} do
      assert_raise YamlElixir.FileNotFoundError, fn ->
        Loader.load!("nonexistent")
      end
    end

    # Confinement E (WI-E3) : un nom de workflow_map/pipeline non-slug ne traverse JAMAIS la racine.
    test "nom de pipeline traversant (../) → REFUSÉ avant Path.join", %{tmp_dir: tmp_dir} do
      # Pose une cible d'évasion : `<root>/../escape.yaml`.
      File.write!(Path.join([tmp_dir, "..", "escape.yaml"]), """
      kind: WorkflowMap
      metadata:
        name: escape
      spec:
        max_rework_rounds: 1
        steps:
          only:
            role: noop
            profile: empty
      """)

      # Sans la garde slug, `Path.join(root, "../escape.yaml")` lirait ce YAML hors-catalogue.
      # `cast!` raise AVANT le Path.join.
      assert_raise ArgumentError, ~r/slug invalide/, fn ->
        Loader.load!("../escape")
      end

      File.rm(Path.join([tmp_dir, "..", "escape.yaml"]))
    end

    test "nom de pipeline avec slash → REFUSÉ", %{tmp_dir: _tmp_dir} do
      assert_raise ArgumentError, ~r/slug invalide/, fn ->
        Loader.load!("a/b")
      end
    end

    test "step avec needs + inputs + gate hard valide", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "complex.yaml"), """
      kind: WorkflowMap
      metadata:
        name: complex
      spec:
        max_rework_rounds: 1
        steps:
          a:
            role: scout
            profile: empty
            outputs:
              - result_id
          b:
            role: archiviste
            profile: empty
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

    test "v2.5 — brief_kind/judge_target/timeout_sec valides → load OK", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "typed.yaml"), """
      kind: WorkflowMap
      metadata:
        name: typed
      spec:
        max_rework_rounds: 1
        steps:
          review:
            role: reviewer
            profile: noop
            brief_kind: judge
            judge_target: brief
            timeout_sec: 600
      """)

      assert %{"steps" => %{"review" => step}} = Loader.load!("typed")
      assert step["brief_kind"] == "judge"
      assert step["judge_target"] == "brief"
    end

    # Propriété de SÉCURITÉ (frontière) : un brief_kind hors {worker, judge} est rejeté au LOAD
    # (fail-closed à la frontière). Il ne peut JAMAIS atteindre le dispatcher pour y être inféré en
    # worker (brief exécutable pour un rôle qui aurait dû être désamorcé).
    test "v2.5 — brief_kind hors-vocab → rejet au load (raise)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "bad_kind.yaml"), """
      kind: WorkflowMap
      metadata:
        name: bad_kind
      spec:
        max_rework_rounds: 1
        steps:
          review:
            role: reviewer
            profile: noop
            brief_kind: reviewer
      """)

      assert_raise RuntimeError, ~r/schema .*invalid/, fn ->
        Loader.load!("bad_kind")
      end
    end

    # additionalProperties:false : un champ inconnu au step est rejeté au load (anti-typo /
    # anti-champ-fantôme) au lieu d'être silencieusement ignoré.
    test "v2.5 — champ de step inconnu → rejet au load (raise)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "unknown_field.yaml"), """
      kind: WorkflowMap
      metadata:
        name: unknown_field
      spec:
        max_rework_rounds: 1
        steps:
          s:
            role: noop
            profile: empty
            bogus_field: oops
      """)

      assert_raise RuntimeError, ~r/schema .*invalid/, fn ->
        Loader.load!("unknown_field")
      end
    end
  end

  describe "load!/2 — validation de graphe" do
    # Schema-VALIDE (needs = array de strings) mais graphe-INVALIDE : `b` réfère un step
    # inexistant. Le schéma laisse passer (contrainte inter-steps inexprimable en draft-07) ;
    # le linter de graphe raise au load — sinon arête fantôme silencieuse → pipeline figé.
    test "workflow_map au needs fantôme (passe le schéma) → raise du linter de graphe", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "phantom.yaml"), """
      kind: WorkflowMap
      metadata:
        name: phantom
      spec:
        max_rework_rounds: 1
        steps:
          a:
            role: noop
            profile: empty
          b:
            role: noop
            profile: empty
            needs: [typo]
      """)

      assert_raise RuntimeError, ~r/phantom edge/, fn ->
        Loader.load!("phantom")
      end
    end

    # Garde-fou anti-régression : toutes les workflow_maps canon doivent passer le linter de graphe.
    # Une workflow_map canon qui échoue ici = soit un vrai bug de workflow_map, soit un invariant trop strict.
    test "toutes les workflow_maps canon passent le linter" do
      canon_dir = Application.app_dir(:fleet_workflow, "priv/canon/workflow_maps")

      names =
        canon_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.map(&Path.basename(&1, ".yaml"))

      refute names == [], "aucune workflow_map canon trouvée dans #{canon_dir}"

      for name <- names do
        assert %{"name" => _, "steps" => _} = Loader.load!(name, workflow_maps_root: canon_dir)
      end
    end
  end
end
