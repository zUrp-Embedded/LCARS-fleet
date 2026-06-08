defmodule Fleet.CapProfile.V25ConformanceTest do
  @moduledoc """
  Lot 5 inc4 — conformité des 7 cap-profiles canon `priv/canon/cap-profiles/` (réabsorbés R0.7)
  au schema `priv/schema/cap-profile-v2.5.json` (critère done Lot 5
  "cap-profiles migrés v2.5"). Pattern Lot 0bis (PROVEN) : YAML canon →
  ex_json_schema validate. `async: true`.

  ## Gap cross-DN tracé — invocation.mode (escaladé architect)
  `fleet_claude_bridge.md` L386 route `selon cap_profile.spec.invocation.mode
  (à ajouter cap-profiles amendement)` MAIS `cap-profiles.md` + le schema
  v2.5 ne définissent PAS `invocation.mode`. Amendement canon jamais ajouté.
  GO-0/#P5 : NON inventé ici (= erreur inférence M1). Routing fonctionnel
  via `Fleet.ClaudeBridge.session_start` `:auto`→RC (défaut DN). Escaladé
  type:request architect (non-bloquant). Ce test valide la conformité
  RÉELLE du schema canon, pas un champ inventé.
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([__DIR__, "..", "priv", "schema", "cap-profile-v2.5.json"])
  @canon_dir Path.join([__DIR__, "..", "priv", "canon", "cap-profiles"])

  @profiles ~w(architect-interactive consultant engineer gatekeeper qualifier reviewer starfleet)

  setup_all do
    schema =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    {:ok, schema: schema}
  end

  test "fixtures présentes (schema + 7 profils canon)" do
    assert File.exists?(@schema_path), "schema absent: #{@schema_path}"

    for p <- @profiles do
      path = Path.join(@canon_dir, "#{p}.yaml")
      assert File.exists?(path), "cap-profile canon absent: #{path}"
    end
  end

  for profile <- @profiles do
    test "cap-profile canon #{profile}.yaml valide cap-profile-v2.5.json", %{schema: schema} do
      canon =
        @canon_dir
        |> Path.join("#{unquote(profile)}.yaml")
        |> YamlElixir.read_from_file!()

      assert :ok = ExJsonSchema.Validator.validate(schema, canon),
             "#{unquote(profile)}.yaml NON conforme cap-profile-v2.5.json : " <>
               inspect(ExJsonSchema.Validator.validate(schema, canon))
    end
  end

  # ── Barrière forge-aveugle §4 — invariant MÉCANIQUE (pas une affiche) ──────
  # DN forge-state-machine §4 + gatekeeper-forge-encoding-v2 §9.9 : les pods
  # producteurs de la chaîne (engineer livrable, gatekeeper verdict) NE touchent
  # JAMAIS la forge — le SYSTÈME (lcars-system) écrit. Vérifié ici, pas seulement
  # commenté dans le yaml (méta-finding audit v2 : « barrières = affiches »).
  # NB hors-scope tracé : architect/consultant/qualifier/reviewer ont encore
  # `fleet-forge.*` ; sous forge-state-machine §4 ils devraient aussi être
  # forge-aveugles (finding complétude barrière, séparé). starfleet = système
  # writer (forge OK, légitime).
  @forge_blind ~w(engineer gatekeeper)
  @forge_write_tools [
    "Bash(git push:*)",
    "Bash(tea issues edit:*)",
    "Bash(tea issues close:*)",
    "Bash(tea comment:*)"
  ]

  for profile <- @forge_blind do
    test "cap-profile #{profile}.yaml est forge-aveugle (barrière §4 mécanique)" do
      canon =
        @canon_dir
        |> Path.join("#{unquote(profile)}.yaml")
        |> YamlElixir.read_from_file!()

      tools = get_in(canon, ["spec", "scope", "allowedTools"]) || []
      denied = get_in(canon, ["spec", "scope", "git_ops_denied"]) || []
      channels = get_in(canon, ["spec", "invocation", "mcp_channels"]) || []

      for forbidden <- @forge_write_tools do
        refute forbidden in tools,
               "#{unquote(profile)} ne doit pas autoriser #{forbidden} (barrière forge-aveugle §4)"
      end

      assert "push" in denied,
             "#{unquote(profile)} doit dénier `push` (git_ops_denied) — barrière mécanique §4"

      refute Enum.any?(channels, &String.starts_with?(&1, "fleet-forge")),
             "#{unquote(profile)} ne doit pas avoir de canal fleet-forge (barrière §4) — vu: #{inspect(channels)}"
    end
  end

  test "négatif — apiVersion manquant rejeté", %{schema: schema} do
    bad = %{"kind" => "CapabilityProfile", "metadata" => %{}, "spec" => %{}}
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "négatif — spec.invocation.lifetime_scope hors enum rejeté", %{schema: schema} do
    base =
      @canon_dir
      |> Path.join("engineer.yaml")
      |> YamlElixir.read_from_file!()

    bad = put_in(base, ["spec", "invocation", "lifetime_scope"], "eternal")
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end
end
