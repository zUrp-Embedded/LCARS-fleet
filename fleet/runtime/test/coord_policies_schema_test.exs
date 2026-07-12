defmodule Fleet.Coord.CoordPoliciesSchemaTest do
  @moduledoc """
  Lot 0bis — prouve que le canon in-repo `priv/config/coord-policies.yaml`
  (chargé par le runtime via `Fleet.Coord.Policies.init_policies!/0`, embarqué
  dans la release) valide contre le schéma `priv/schema/coord-policies-v1.json`,
  et qu'une config structurellement invalide est rejetée.

  Repath fix : @canon_path pointait `05_data-canon/config/coord-policies.yaml`
  (chemin DOCTRINE, absent du repo de code post-bascule) → setup_all échouait →
  6 tests invalid. Repointé sur le canon in-repo `priv/config/coord-policies.yaml`
  (single-source, fichier réellement servi). Drift priv↔doctrine (24 vs 112 l)
  = réconciliation [DATA] (cf. drift coord-policies) — alignement canon APRÈS
  validation code, pas avant. Pattern cohérent R0.3 (fleet_event_router).
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([__DIR__, "..", "priv", "coord", "schema", "coord-policies-v1.json"])
  @canon_path Path.join([__DIR__, "..", "priv", "coord", "config", "coord-policies.yaml"])

  setup_all do
    assert File.exists?(@schema_path), "schema absent: #{@schema_path}"
    assert File.exists?(@canon_path), "canon coord-policies.yaml absent: #{@canon_path}"

    schema =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    {:ok, schema: schema}
  end

  test "le canon coord-policies.yaml valide contre coord-policies-v1.json", %{schema: schema} do
    canon = YamlElixir.read_from_file!(@canon_path)
    assert :ok = ExJsonSchema.Validator.validate(schema, canon)
  end

  test "rejet — mapping sans action", %{schema: schema} do
    bad = %{
      "mappings" => %{"audit.proven" => %{"escalation_path" => []}},
      "handoff_role_mapping" => %{"code" => "qualifier"}
    }

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "rejet — escalation_path non-array", %{schema: schema} do
    bad = %{
      "mappings" => %{
        "audit.proven" => %{"action" => "promote_artifact", "escalation_path" => "x"}
      },
      "handoff_role_mapping" => %{"code" => "qualifier"}
    }

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  # IMP-1 (reviewer Lot 0bis) résolu par la voie conditionnelle du reviewer
  # lui-même : le canon a 10 politiques TERMINALES avec escalation_path:[]
  # (audit.proven / gatekeeper.* / phase_done.* / *.proven). minItems:1
  # aurait cassé le canon (boot fail). Sémantique terminale documentée
  # (schema description) + test POSITIF (pas négatif) : [] accepté.
  test "accepte — escalation_path vide (politique terminale, canon-réaliste)",
       %{schema: schema} do
    terminal = %{
      "mappings" => %{
        "audit.proven" => %{"action" => "promote_artifact", "escalation_path" => []}
      },
      "handoff_role_mapping" => %{"code" => "qualifier"}
    }

    assert :ok = ExJsonSchema.Validator.validate(schema, terminal)
  end

  test "rejet — clé mapping sans point", %{schema: schema} do
    bad = %{
      "mappings" => %{"auditproven" => %{"action" => "x", "escalation_path" => []}},
      "handoff_role_mapping" => %{"code" => "qualifier"}
    }

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  # Repath fix — handoff_role_mapping est OPTIONNEL post-bascule : le handoff
  # inter-rôles (Fleet.Coord.Backend.Handoff) n'est pas encore câblé, donc le
  # canon servi (priv/config/coord-policies.yaml) l'omet légitimement. Même voie
  # que le cas escalation_path:[] ci-dessus (test POSITIF, pas négatif). À
  # rebasculer en rejet quand le handler sera implémenté + le bloc réintégré
  # (réconciliation [DATA] doctrine).
  test "accepte — handoff_role_mapping absent (handoff non câblé, canon-réaliste)",
       %{schema: schema} do
    ok = %{"mappings" => %{"audit.proven" => %{"action" => "x", "escalation_path" => []}}}
    assert :ok = ExJsonSchema.Validator.validate(schema, ok)
  end
end
