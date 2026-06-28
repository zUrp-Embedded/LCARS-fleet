defmodule Fleet.Pipeline.LoaderTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.Pipeline.Loader

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_pipeline, :pipelines_root, tmp_dir)

    on_exit(fn ->
      Application.delete_env(:fleet_pipeline, :pipelines_root)
    end)

    :ok
  end

  describe "load!/1" do
    test "pipeline minimal valide → map", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "minimal.yaml"), """
      kind: Pipeline
      metadata:
        name: minimal
      spec:
        stages:
          only:
            role: noop
            profile: empty
      """)

      # Forme normalisée `%{"name", "stages"}` : l'enveloppe (kind/metadata/spec)
      # est déballée au load, seuls `name` (depuis metadata) et `stages` survivent.
      assert %{"name" => "minimal", "stages" => %{"only" => _}} =
               Loader.load!("minimal")
    end

    test "schema invalide (champ stages manquant) → raise", %{tmp_dir: tmp_dir} do
      # Enveloppe v2.5 valide mais `spec.stages` absent → `spec` exige `stages`.
      File.write!(Path.join(tmp_dir, "invalid.yaml"), """
      kind: Pipeline
      metadata:
        name: invalid
      spec: {}
      """)

      assert_raise RuntimeError, ~r/schema .*invalide/, fn ->
        Loader.load!("invalid")
      end
    end

    test "schema invalide (gate type non-supporté) → raise", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "bad_gate.yaml"), """
      kind: Pipeline
      metadata:
        name: bad_gate
      spec:
        stages:
          s1:
            role: noop
            profile: empty
            gate:
              type: hocus_pocus
      """)

      assert_raise RuntimeError, ~r/schema .*invalide/, fn ->
        Loader.load!("bad_gate")
      end
    end

    test "fichier introuvable → YamlElixir.FileNotFoundError", %{tmp_dir: _tmp_dir} do
      assert_raise YamlElixir.FileNotFoundError, fn ->
        Loader.load!("nonexistent")
      end
    end

    # Confinement E (WI-E3) : un nom de carte/pipeline non-slug ne traverse JAMAIS la racine.
    test "nom de pipeline traversant (../) → REFUSÉ avant Path.join", %{tmp_dir: tmp_dir} do
      # Pose une cible d'évasion : `<root>/../escape.yaml`.
      File.write!(Path.join([tmp_dir, "..", "escape.yaml"]), """
      kind: Pipeline
      metadata:
        name: escape
      spec:
        stages:
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

    test "stage avec needs + inputs + gate hard valide", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "complex.yaml"), """
      kind: Pipeline
      metadata:
        name: complex
      spec:
        stages:
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
              rule:
                status: ok
      """)

      assert %{"stages" => %{"a" => _, "b" => stage_b}} = Loader.load!("complex")
      assert stage_b["needs"] == ["a"]
      assert stage_b["gate"]["type"] == "hard"
    end

    test "v2.5 — mandate_kind/judge_target/timeout_sec valides → load OK", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "typed.yaml"), """
      kind: Pipeline
      metadata:
        name: typed
      spec:
        stages:
          review:
            role: reviewer
            profile: noop
            mandate_kind: judge
            judge_target: mandate
            timeout_sec: 600
      """)

      assert %{"stages" => %{"review" => stage}} = Loader.load!("typed")
      assert stage["mandate_kind"] == "judge"
      assert stage["judge_target"] == "mandate"
    end

    # Propriété de SÉCURITÉ (frontière) : un mandate_kind hors {worker, judge} est rejeté au LOAD
    # (fail-closed à la frontière). Il ne peut JAMAIS atteindre le dispatcher pour y être inféré en
    # worker (mandat exécutable pour un rôle qui aurait dû être désamorcé).
    test "v2.5 — mandate_kind hors-vocab → rejet au load (raise)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "bad_kind.yaml"), """
      kind: Pipeline
      metadata:
        name: bad_kind
      spec:
        stages:
          review:
            role: reviewer
            profile: noop
            mandate_kind: reviewer
      """)

      assert_raise RuntimeError, ~r/schema .*invalide/, fn ->
        Loader.load!("bad_kind")
      end
    end

    # additionalProperties:false : un champ inconnu au stage est rejeté au load (anti-typo /
    # anti-champ-fantôme) au lieu d'être silencieusement ignoré.
    test "v2.5 — champ de stage inconnu → rejet au load (raise)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "unknown_field.yaml"), """
      kind: Pipeline
      metadata:
        name: unknown_field
      spec:
        stages:
          s:
            role: noop
            profile: empty
            bogus_field: oops
      """)

      assert_raise RuntimeError, ~r/schema .*invalide/, fn ->
        Loader.load!("unknown_field")
      end
    end
  end

  describe "load!/2 — validation de graphe" do
    # Schema-VALIDE (needs = array de strings) mais graphe-INVALIDE : `b` réfère un stage
    # inexistant. Le schéma laisse passer (contrainte inter-stages inexprimable en draft-07) ;
    # le linter de graphe raise au load — sinon arête fantôme silencieuse → pipeline figé.
    test "carte au needs fantôme (passe le schéma) → raise du linter de graphe", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "phantom.yaml"), """
      kind: Pipeline
      metadata:
        name: phantom
      spec:
        stages:
          a:
            role: noop
            profile: empty
          b:
            role: noop
            profile: empty
            needs: [typo]
      """)

      assert_raise RuntimeError, ~r/arête fantôme/, fn ->
        Loader.load!("phantom")
      end
    end

    # Garde-fou anti-régression : toutes les cartes canon doivent passer le linter de graphe.
    # Une carte canon qui échoue ici = soit un vrai bug de carte, soit un invariant trop strict.
    test "toutes les cartes canon passent le linter" do
      canon_dir = Application.app_dir(:fleet_pipeline, "priv/canon/pipelines")

      names =
        canon_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.map(&Path.basename(&1, ".yaml"))

      refute names == [], "aucune carte canon trouvée dans #{canon_dir}"

      for name <- names do
        assert %{"name" => _, "stages" => _} = Loader.load!(name, pipelines_root: canon_dir)
      end
    end
  end
end
