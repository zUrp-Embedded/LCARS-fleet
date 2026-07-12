defmodule Fleet.CapProfile.V25ConformanceTest do
  @moduledoc """
  Lot 5 inc4 — conformité des 7 cap-profiles canon `priv/canon/cap-profiles/` (réabsorbés R0.7)
  au schema `priv/schema/cap-profile-v2.5.json` (critère done Lot 5
  "cap-profiles migrés v2.5"). Pattern Lot 0bis (PROVEN) : YAML canon →
  ex_json_schema validate. `async: true`.

  Ce test valide la conformité RÉELLE des cap-profiles au schema canon v2.5,
  pas un champ inventé (GO-0/#P5). NB historique : `invocation.mode` (jamais
  ajouté au schema) devait router via `fleet_claude_bridge` — app **retirée au
  pivot ADR-G** (RC interactif) ; le routing par `invocation.mode` est obsolète.
  """
  use ExUnit.Case, async: true

  @schema_path Path.join([
                 __DIR__,
                 "..",
                 "priv",
                 "cap_profile",
                 "schema",
                 "cap-profile-v2.5.json"
               ])
  @canon_dir Path.join([__DIR__, "..", "priv", "cap_profile", "canon", "cap-profiles"])

  @profiles ~w(architect consultant engineer gatekeeper qualifier reviewer starfleet)

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
  # F-C007 (résolu, user-validé) : les JUGES (qualifier, reviewer — brief_kind: judge) reçoivent un clone
  # in-pod, bossent dessus, rendent un verdict payload → RIEN à faire avec la forge → forge-aveugles.
  # architect = user-facing (répond de l'état forge à l'user en lecture, initie clone/branch/feature sur
  # demande — sécu déléguée au classifier Anthropic) → GARDE fleet-forge (hors @forge_blind, légitime).
  # consultant = worker (juge seulement via override per-step) → cas à part, non tranché. starfleet = système.
  @forge_blind ~w(engineer gatekeeper qualifier reviewer)
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

  test "négatif — apiVersion (champ legacy v2.4 RETIRÉ) rejeté au lieu d'être ignoré (F-C006)",
       %{schema: schema} do
    # `apiVersion` a été RETIRÉ du schéma v2.5 (il n'est ni property ni required). Le nom historique de ce
    # test (« apiVersion manquant rejeté ») était devenu un MENSONGE : son `bad` (metadata/spec vides) était
    # rejeté pour `required` manquant, PAS pour apiVersion — le concept n'existe plus. On teste ce qui est
    # RÉELLEMENT vérifiable et load-bearing : un profil legacy portant ENCORE `apiVersion` doit être REJETÉ
    # (root additionalProperties:false, R0-CAP-001), jamais silencieusement accepté. On part d'un profil canon
    # VALIDE et on n'ajoute QUE apiVersion → la seule cause de rejet possible est ce champ inconnu (sinon le
    # test prouverait autre chose, cf. l'ancienne version).
    base =
      @canon_dir
      |> Path.join("engineer.yaml")
      |> YamlElixir.read_from_file!()

    assert :ok = ExJsonSchema.Validator.validate(schema, base),
           "le profil canon de base doit être valide, sinon l'isolation d'apiVersion ne tient pas : " <>
             inspect(ExJsonSchema.Validator.validate(schema, base))

    with_api_version = Map.put(base, "apiVersion", "lcars/v2.4")

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, with_api_version),
           "un profil portant encore `apiVersion` (legacy v2.4) doit être REJETÉ (additionalProperties:false)"
  end

  test "négatif — spec.invocation.lifetime_scope hors enum rejeté", %{schema: schema} do
    base =
      @canon_dir
      |> Path.join("engineer.yaml")
      |> YamlElixir.read_from_file!()

    bad = put_in(base, ["spec", "invocation", "lifetime_scope"], "eternal")
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "négatif — spec.brief_kind MANQUANT rejeté (judge-ness jamais inférée)", %{schema: schema} do
    # Verrou amont du repli mou #2 : brief_kind absent → défaut code `worker` = EXÉCUTE (issue brute).
    # Un rôle JUGE qui oublie `brief_kind: judge` retomberait sur worker → il exécuterait le contenu
    # attaquant au lieu de le juger. « judge-ness = propriété de sécurité, jamais inférée » : brief_kind
    # est REQUIS au schéma → un profil sans lui est rejeté AU LOAD, le défaut worker devient inatteignable.
    base =
      @canon_dir
      |> Path.join("engineer.yaml")
      |> YamlElixir.read_from_file!()

    {_, bad} = pop_in(base, ["spec", "brief_kind"])

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad),
           "un cap-profile sans brief_kind doit être REJETÉ au load (worker=exécute par omission = fail-open)"
  end

  test "négatif — spec.scope.allowedTools / disallowedTools MANQUANT rejeté (F-C141 : hard-requis par claude_launch)",
       %{schema: schema} do
    # `bin/claude_launch.sh` fait `jq -r '.spec.scope.allowedTools | join(",")' || exit 1` (idem
    # disallowedTools) : un champ ABSENT → `join` sur null → jq rc=5 → le `|| exit 1` fire → le pod ne se
    # lance JAMAIS (crash au spawn). Verrou-amont D4 : le schéma DOIT rejeter au LOAD un profil qui
    # crasherait le launcher, pas le laisser passer pour exploser au spawn. Les 7 profils canon les portent.
    base =
      @canon_dir
      |> Path.join("engineer.yaml")
      |> YamlElixir.read_from_file!()

    for field <- ["allowedTools", "disallowedTools"] do
      {_, bad} = pop_in(base, ["spec", "scope", field])

      assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad),
             "un cap-profile sans spec.scope.#{field} doit être REJETÉ au load (hard-requis par claude_launch, F-C141)"
    end
  end

  test "négatif — champ INCONNU (typo) rejeté à chaque niveau (additionalProperties:false, R0-CAP-001)",
       %{schema: schema} do
    base =
      @canon_dir
      |> Path.join("engineer.yaml")
      |> YamlElixir.read_from_file!()

    # Un champ mistypé (ex. `containmnet`) doit être REJETÉ, pas silencieusement ignoré → sinon le pod
    # tourne avec le défaut inattendu. On couvre top-level, metadata, spec, spec.invocation.
    for {path, label} <- [
          {["unknown_top"], "top-level"},
          {["metadata", "containmnet"], "metadata"},
          {["spec", "unknown_spec_field"], "spec"},
          {["spec", "invocation", "typo_field"], "spec.invocation"}
        ] do
      bad = put_in(base, path, "x")

      assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad),
             "un champ inconnu au niveau #{label} doit être rejeté (schema strict)"
    end
  end

  test "R0-CAP-011 : enums du schéma == enums code (SSoT lock, détecte le drift schéma↔code)" do
    raw = @schema_path |> File.read!() |> Jason.decode!()

    # lifetime_scope : dupliqué schéma ↔ Invariants.@lifetime_scope_enum (dedup physique impossible :
    # JSON-schema ne peut pas référencer de l'Elixir → on VERROUILLE les deux copies par ce test).
    schema_ls =
      get_in(raw, [
        "properties",
        "spec",
        "properties",
        "invocation",
        "properties",
        "lifetime_scope",
        "enum"
      ])

    assert schema_ls == Fleet.CapProfile.Invariants.lifetime_scope_enum(),
           "drift lifetime_scope : schéma #{inspect(schema_ls)} ≠ code #{inspect(Fleet.CapProfile.Invariants.lifetime_scope_enum())}"

    # slot_scope : dupliqué schéma ↔ le littéral de l'accessor `slot_scope/1`.
    schema_ss = get_in(raw, ["properties", "metadata", "properties", "slot_scope", "enum"])
    assert schema_ss == ["project", "instance"]
  end

  test "F-C138/F-C142 : architect expose import_project via mcp_fleet_tools (canon → surface MCP, single source)" do
    # Le canon (`architect.yaml` allowedTools) est la SEULE source de la surface MCP rôle : le spawner la
    # thread au central qui sert `tools/list`. `import_project` (jumeau de create_project, deftool câblé)
    # doit y figurer maintenant qu'il est déclaré — plus jamais de dérive Python↔Elixir.
    canon = @canon_dir |> Path.join("architect.yaml") |> YamlElixir.read_from_file!()
    cp = %Fleet.CapProfile{kind: canon["kind"], metadata: canon["metadata"], spec: canon["spec"]}
    tools = Fleet.CapProfile.mcp_fleet_tools(cp)

    assert "import_project" in tools
    assert "create_project" in tools and "create_issue" in tools and "get_issue_status" in tools
  end
end
