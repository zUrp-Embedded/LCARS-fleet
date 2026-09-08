defmodule Fleet.CapProfile.ConformanceTest do
  @moduledoc """
  Conformance of the 7 canon cap-profiles `priv/catalogue/cap_profile/cap-profiles/` against the
  schema `priv/schema/cap-profile.json`. Pattern (PROVEN): canon YAML →
  ex_json_schema validate. `async: true`.

  This test validates the REAL conformance of the cap-profiles to the canon
  schema, not an invented field (GO-0/#P5). Historical note: `invocation.mode`
  (never added to the schema) was meant to route via `fleet_claude_bridge` — an
  app **removed at the ADR-G pivot** (interactive RC); routing by
  `invocation.mode` is obsolete.
  """
  use ExUnit.Case, async: true

  alias Fleet.CapProfile.Invariants

  @schema_path Path.join([
                 __DIR__,
                 "..",
                 "..",
                 "..",
                 "priv",
                 "cap_profile",
                 "schema",
                 "cap-profile.json"
               ])
  # LES DEUX racines : la mecanique (architect, gatekeeper, starfleet, chief) vit dans le catalogue
  # systeme, le metier dans l'autre. Le schema est le meme pour les deux — c'est precisement ce que
  # ce test mesure — donc l'inventaire se resout par recherche, jamais par une racine en dur.
  @canon_dirs [
    Path.join([
      __DIR__,
      "..",
      "..",
      "..",
      "priv",
      "catalogue-system",
      "cap_profile",
      "cap-profiles"
    ]),
    Path.join([
      __DIR__,
      "..",
      "..",
      "..",
      "priv",
      "catalogue",
      "cap_profile",
      "cap-profiles"
    ])
  ]

  defp canon_path(role) do
    Enum.find_value(@canon_dirs, fn dir ->
      path = Path.join(dir, "#{role}.yaml")
      if File.exists?(path), do: path
    end)
  end

  @profiles ~w(architect engineer gatekeeper qualifier reviewer scoper starfleet)

  setup_all do
    schema =
      @schema_path
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    {:ok, schema: schema}
  end

  test "fixtures present (schema + 7 canon profiles)" do
    assert File.exists?(@schema_path), "schema missing: #{@schema_path}"

    for p <- @profiles do
      assert canon_path(p), "canon cap-profile missing: #{p}.yaml (ni systeme ni metier)"
    end
  end

  for profile <- @profiles do
    test "canon cap-profile #{profile}.yaml validates cap-profile.json", %{schema: schema} do
      canon = unquote(profile) |> canon_path() |> YamlElixir.read_from_file!()

      assert :ok = ExJsonSchema.Validator.validate(schema, canon),
             "#{unquote(profile)}.yaml NOT conformant to cap-profile.json: " <>
               inspect(ExJsonSchema.Validator.validate(schema, canon))
    end
  end

  # ── Forge-blind barrier §4 — MECHANICAL invariant (not a poster) ───────────
  # DN forge-state-machine §4 + gatekeeper-forge-encoding-v2 §9.9: the producer
  # pods of the chain (engineer deliverable, gatekeeper verdict) NEVER touch
  # the forge — the SYSTEM (system_starfleet) writes. Verified here, not merely
  # commented in the yaml (audit meta-finding: "barriers = posters").
  # F-C007 (resolved, user-validated): the JUDGES (qualifier, reviewer — brief_kind: judge) receive an
  # in-pod clone, work on it, return a verdict payload → NOTHING to do with the forge → forge-blind.
  # architect = user-facing (answers the user about forge state read-only, initiates clone/branch/feature
  # on demand — security delegated to the Anthropic classifier) → KEEPS fleet-forge (outside @forge_blind,
  # legitimate). scoper = NATIVE judge since the 2026-07-30 split (it was the unsettled "worker judged by
  # per-step override" case): it judges a brief and returns a verdict payload, so it belongs with the
  # forge-blind judges below. starfleet = system.
  @forge_blind ~w(engineer gatekeeper qualifier reviewer scoper)
  @forge_write_tools [
    "Bash(git push:*)",
    "Bash(tea issues edit:*)",
    "Bash(tea issues close:*)",
    "Bash(tea comment:*)"
  ]

  for profile <- @forge_blind do
    test "cap-profile #{profile}.yaml is forge-blind (mechanical §4 barrier)" do
      canon = unquote(profile) |> canon_path() |> YamlElixir.read_from_file!()

      tools = get_in(canon, ["spec", "scope", "allowedTools"]) || []
      denied = get_in(canon, ["spec", "scope", "git_ops_denied"]) || []

      for forbidden <- @forge_write_tools do
        refute forbidden in tools,
               "#{unquote(profile)} must not allow #{forbidden} (forge-blind barrier §4)"
      end

      assert "push" in denied,
             "#{unquote(profile)} must deny `push` (git_ops_denied) — mechanical §4 barrier"
    end
  end

  test "negative — apiVersion (legacy v2.4 field REMOVED) rejected instead of ignored (F-C006)",
       %{schema: schema} do
    # `apiVersion` is not in the schema (it is neither a property nor required). We test what
    # is ACTUALLY verifiable and load-bearing: a legacy profile STILL carrying `apiVersion` must be
    # REJECTED (root additionalProperties:false, R0-CAP-001), never silently accepted. We start from a
    # VALID canon profile and ONLY add apiVersion → the only possible rejection cause is that unknown
    # field (otherwise the test would prove something else, e.g. a rejection for missing `required`).
    base =
      "engineer" |> canon_path() |> YamlElixir.read_from_file!()

    assert :ok = ExJsonSchema.Validator.validate(schema, base),
           "the base canon profile must be valid, otherwise apiVersion isolation does not hold: " <>
             inspect(ExJsonSchema.Validator.validate(schema, base))

    with_api_version = Map.put(base, "apiVersion", "lcars/v2.4")

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, with_api_version),
           "a profile still carrying `apiVersion` (legacy v2.4) must be REJECTED (additionalProperties:false)"
  end

  test "negative — spec.invocation.lifetime_scope outside enum rejected", %{schema: schema} do
    base =
      "engineer" |> canon_path() |> YamlElixir.read_from_file!()

    bad = put_in(base, ["spec", "invocation", "lifetime_scope"], "eternal")
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad)
  end

  test "negative — MISSING spec.brief_kind rejected (judge-ness never inferred)", %{
    schema: schema
  } do
    # Upstream lock of soft-fallback #2: brief_kind absent → code default `worker` = EXECUTES (raw issue).
    # A JUDGE role that forgets `brief_kind: judge` would fall back to worker → it would execute the
    # attacker content instead of judging it. "judge-ness = security property, never inferred": brief_kind
    # is REQUIRED by the schema → a profile without it is rejected AT LOAD, the worker default becomes
    # unreachable.
    base =
      "engineer" |> canon_path() |> YamlElixir.read_from_file!()

    {_, bad} = pop_in(base, ["spec", "brief_kind"])

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad),
           "a cap-profile without brief_kind must be REJECTED at load (worker=executes by omission = fail-open)"
  end

  test "negative — MISSING spec.scope.allowedTools / disallowedTools rejected (F-C141: hard-required by claude_launch)",
       %{schema: schema} do
    # `bin/claude_launch.sh` does `jq -r '.spec.scope.allowedTools | join(",")' || exit 1` (same for
    # disallowedTools): an ABSENT field → `join` on null → jq rc=5 → the `|| exit 1` fires → the pod NEVER
    # launches (crash at spawn). Upstream lock D4: the schema MUST reject at LOAD a profile that would
    # crash the launcher, not let it through to explode at spawn. All 7 canon profiles carry them.
    base =
      "engineer" |> canon_path() |> YamlElixir.read_from_file!()

    for field <- ["allowedTools", "disallowedTools"] do
      {_, bad} = pop_in(base, ["spec", "scope", field])

      assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad),
             "a cap-profile without spec.scope.#{field} must be REJECTED at load (hard-required by claude_launch, F-C141)"
    end
  end

  test "negative — UNKNOWN field (typo) rejected at every level (additionalProperties:false, R0-CAP-001)",
       %{schema: schema} do
    base =
      "engineer" |> canon_path() |> YamlElixir.read_from_file!()

    # A mistyped field (e.g. `containmnet`) must be REJECTED, not silently ignored → otherwise the pod
    # runs with the unexpected default. We cover top-level, metadata, spec, spec.invocation.
    for {path, label} <- [
          {["unknown_top"], "top-level"},
          {["metadata", "containmnet"], "metadata"},
          {["spec", "unknown_spec_field"], "spec"},
          {["spec", "invocation", "typo_field"], "spec.invocation"}
        ] do
      bad = put_in(base, path, "x")

      assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad),
             "an unknown field at level #{label} must be rejected (strict schema)"
    end
  end

  test "R0-CAP-011: schema enums == code enums (SSoT lock, detects schema↔code drift)" do
    raw = @schema_path |> File.read!() |> Jason.decode!()

    # lifetime_scope: duplicated schema ↔ Invariants.@lifetime_scope_enum (physical dedup impossible:
    # JSON-schema cannot reference Elixir → we LOCK both copies with this test).
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

    assert schema_ls == Invariants.lifetime_scope_enum(),
           "lifetime_scope drift: schema #{inspect(schema_ls)} ≠ code #{inspect(Invariants.lifetime_scope_enum())}"

    # ⚠ LE CONFINEMENT, ET IL A ETE LE SEUL DES DEUX SANS SA MOITIE SCHEMA. Mesure du 2026-09-08 :
    # `metadata.containment` etait type `"string"` NU, donc `@containment_enum` etait le SEUL portail
    # sur une valeur qui decide du bac a sable — `bwrap?/1` en derive, et un profil non-bwrap prend
    # le chemin hote (aucun proxy CONNECT, range avec les host-native par `SpawnAdmission`).
    #
    # Y ajouter un mot — l'edition qui se lit « on supporte docker maintenant » — passait
    # `validate/1`, passait le schema, et ne faisait rougir AUCUN des 3 774 tests. Les deux temoins
    # qui pretendaient garder l'invariant posaient la meme unique valeur hors-liste (`"ad-hoc"`), et
    # elargir une liste blanche ne rougit que le membre qu'on y ajoute, jamais celui qu'on teste.
    #
    # C'est l'ecart avec `lifetime_scope` juste au-dessus qui est le fait : la technique etait a
    # quinze lignes, elle n'avait pas ete appliquee a celui des deux qui garde l'isolation.
    schema_ct =
      get_in(raw, ["properties", "metadata", "properties", "containment", "enum"])

    assert schema_ct == Invariants.containment_enum(),
           "containment drift: schema #{inspect(schema_ct)} \u2260 code #{inspect(Invariants.containment_enum())}"

    # slot_scope is NO LONGER a schema enum: it DERIVES from lifetime_scope
    # (`CapProfile.slot_scope/1`, one-shot→instance / else→project) → no copy left to lock here.
    refute get_in(raw, ["properties", "metadata", "properties", "slot_scope"]),
           "slot_scope must no longer be declared in the schema (derived from lifetime_scope)"
  end

  test "F-C138/F-C142: canon → MCP surface reflects the two heads (onboarding=starfleet, delegation=architect)" do
    # The canon (`<role>.yaml` allowedTools) is the ONLY source of the role MCP surface: the spawner
    # threads it to the central which serves `tools/list`. Since the 2026-07-19 reorg the two heads are
    # split — this proves the canon carries the split, no Python↔Elixir drift, ever.
    tools = fn role ->
      canon = role |> canon_path() |> YamlElixir.read_from_file!()

      cp = %Fleet.CapProfile{
        kind: canon["kind"],
        metadata: canon["metadata"],
        spec: canon["spec"]
      }

      Fleet.CapProfile.mcp_fleet_tools(cp)
    end

    # starfleet = ONBOARDING head (portfolio).
    sf = tools.("starfleet")
    assert "project_create" in sf and "project_install" in sf and "card_list" in sf
    refute "issue_create" in sf

    # architect = DELEGATION head (its project) — NOT onboarding.
    arch = tools.("architect")
    assert "issue_create" in arch and "issue_status" in arch and "escalation_list" in arch
    refute "project_create" in arch
    refute "project_install" in arch
  end

  test "F-05 (codex audit): no canon profile default-injects a modop whose SP contradicts its lifecycle" do
    # fire-mode's v1.5 doctrine (JSON on stdout, self-exit one-shot) predates MCP submit_result:
    # injected into a pipe/forever profile it ORDERS the agent the opposite of the runtime
    # protocol — an executed contract, not lateral documentation. Semantic guard on the DATA:
    # a non-one-shot profile must not default a one-shot-doctrine modop.
    modop_sp = fn name ->
      path =
        Path.join([
          __DIR__,
          "..",
          "..",
          "..",
          "priv",
          "catalogue",
          "cap_profile",
          "modop-bundles",
          name,
          "sp.md"
        ])

      case File.read(path) do
        {:ok, body} -> body
        _ -> ""
      end
    end

    # ONE role inventory (@profiles) — a second inline list could silently drift from it.
    for profile <- @profiles do
      raw = YamlElixir.read_from_file!(canon_path(profile))
      scope = get_in(raw, ["spec", "invocation", "lifetime_scope"])
      defaults = get_in(raw, ["spec", "modop_set", "default"]) || []

      if scope != "one-shot" do
        for modop <- defaults do
          body = modop_sp.(modop)

          # Fingerprint = fire-mode's IRON-LAW line, not the bare word (long-session-discipline
          # legitimately MENTIONS one-shot to contrast itself — prose about ≠ doctrine of).
          refute body =~ "ONE-SHOT execution",
                 "#{profile} (#{scope}) default-injects modop #{modop} carrying one-shot doctrine"

          refute body =~ "Lifetime_scope = `one-shot`",
                 "#{profile} (#{scope}) default-injects modop #{modop} carrying one-shot doctrine"
        end
      end
    end
  end

  test "spec.systemPrompt is ADMITTED by the schema — it was forbidden, and the code read it anyway" do
    # Measured 2026-08-10: `spec` carries `additionalProperties: false` and did not declare
    # `systemPrompt`, so a catalogue using it was refused at image publish. Meanwhile ~50 lines of
    # runtime resolved it, with an image key, a knob and two path guards, documented as a "dormant
    # EXTENSION POINT". Dormant reads as "nobody uses it yet"; the truth was "nobody CAN".
    raw =
      Application.app_dir(
        :lcars_fleet,
        "priv/catalogue-system/cap_profile/cap-profiles/architect.yaml"
      )
      |> YamlElixir.read_from_file!()

    assert :ok = Fleet.CapProfile.Schema.validate(raw, :cap_profile)

    borrowing = put_in(raw, ["spec", "systemPrompt"], "architect")
    assert :ok = Fleet.CapProfile.Schema.validate(borrowing, :cap_profile)

    # And it stays STRICT around it: the neighbouring typo is still refused.
    typo = put_in(raw, ["spec", "systemPromt"], "architect")
    assert {:error, :invalid_schema} = Fleet.CapProfile.Schema.validate(typo, :cap_profile)
  end

  test "B-03 (catalogue L3): the canon roles carry the RIGHT capabilities (data, not magic names)" do
    cap = fn role ->
      {:ok, p} = Fleet.CapProfile.load(role)
      p
    end

    assert Fleet.CapProfile.has_capability?(cap.("architect"), :project_delegate)
    # The architect is NOT an onboarder: enrolling a project into the fleet is done from outside
    # any project, and this role lives inside one. It declared the capability and carried no tool
    # the capability gates — a permission that granted nothing and described nothing.
    refute Fleet.CapProfile.has_capability?(cap.("architect"), :onboarder)
    assert Fleet.CapProfile.has_capability?(cap.("starfleet"), :onboarder)
    refute Fleet.CapProfile.has_capability?(cap.("starfleet"), :project_delegate)
    assert Fleet.CapProfile.has_capability?(cap.("gatekeeper"), :exception_judge)
    assert Fleet.CapProfile.has_capability?(cap.("engineer"), :producer)
    refute Fleet.CapProfile.has_capability?(cap.("engineer"), :onboarder)

    # The judges are NOT onboarders/delegates — the gates must refuse them.
    for judge <- ~w(scoper qualifier reviewer) do
      refute Fleet.CapProfile.has_capability?(cap.(judge), :onboarder)
      refute Fleet.CapProfile.has_capability?(cap.(judge), :project_delegate)
    end
  end

  describe "modop overlays are IDENTITY (a modop changes behavior via its SP bundle, never the profile)" do
    test "every canon modop profile.yaml parses to the EMPTY map" do
      # A non-empty overlay would mutate the role's cap-profile identity AT SPAWN, silently sized
      # by whichever modop happens to be active — capabilities, scope and containment must never
      # vary by modop. The canon commits to `{}`; this pins it: a future modop that NEEDS a real
      # overlay must edit this test — a visible design decision, not a quiet deep-merge.
      overlays = Enum.flat_map(@canon_dirs, &Path.wildcard(Path.join(&1, "modop/*/profile.yaml")))
      assert overlays != [], "no modop overlays found - canon moved?"

      for overlay <- overlays do
        assert {:ok, %{} = parsed} = YamlElixir.read_from_file(overlay)

        assert parsed == %{},
               "#{overlay}: NON-IDENTITY modop overlay #{inspect(parsed)} - a modop must not " <>
                 "mutate the cap-profile (behavior goes through its SP bundle)"
      end
    end
  end

  describe "kick reachability (a pod the machine spawns must be startable)" do
    test "starfleet is the ONLY canon role gating send-keys" do
      # `invocation.wake_send_keys: false` gates EVERY send-keys, `engage` included — not just the
      # wake fallback it reads like. For a pod the machine spawns with no brief enqueued, the
      # kick loop then cancels itself (`bootstrap? and not profile_send_keys?`) and the pod sits
      # at an untouched prompt forever: started, alive, and unreachable. Only a pod a HUMAN is
      # already typing into can afford that, and starfleet is the sole role of that class.
      # A second role landing here means somebody copied the flag onto a machine-spawned pod
      # and shipped an architect (or a worker) that never boots.
      flag_only =
        for p <- @profiles,
            raw = YamlElixir.read_from_file!(canon_path(p)),
            get_in(raw, ["spec", "invocation", "wake_send_keys"]) == false,
            do: p

      assert flag_only == ["starfleet"],
             "roles gating every send-keys: #{inspect(flag_only)} — expected only starfleet " <>
               "(a machine-spawned pod with this flag never receives its bootstrap kick)"
    end
  end
end
