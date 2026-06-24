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
      name: minimal
      version: 1
      stages:
        only:
          role: noop
          profile: empty
      """)

      # U1 (R3) : forme normalisée `%{"name", "stages"}` — `version` (marqueur
      # de format source) est écarté, aucun consommateur runtime ne le lit.
      assert %{"name" => "minimal", "stages" => %{"only" => _}} =
               Loader.load!("minimal")
    end

    test "schema invalide (champ stages manquant) → raise", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "invalid.yaml"), """
      name: invalid
      version: 1
      """)

      assert_raise RuntimeError, ~r/schema .*invalide/, fn ->
        Loader.load!("invalid")
      end
    end

    test "schema invalide (gate type non-supporté) → raise", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "bad_gate.yaml"), """
      name: bad_gate
      version: 1
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
      name: escape
      version: 1
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
      name: complex
      version: "1.0"
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
            - from_stage: a
              key: result_id
          gate:
            type: hard
            rule:
              status: ok
      """)

      assert %{"stages" => %{"a" => _, "b" => stage_b}} = Loader.load!("complex")
      assert stage_b["needs"] == ["a"]
      assert stage_b["gate"]["type"] == "hard"
    end
  end
end
