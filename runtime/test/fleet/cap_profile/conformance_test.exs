defmodule Fleet.CapProfile.ConformanceTest do
  @moduledoc """
  Checks the explicitly listed bundled profiles against `priv/cap_profile/schema/cap-profile.json`,
  plus selected tool/capability declarations and schema/code enum agreement.
  The fixed role list is a subset, not an exhaustive catalogue scan or launch-enforcement test.
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
  # Find the selected fixtures in either bundled tree; both use the same schema.
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

  # Worker/judge roles return payloads for system-mediated forge writes; architect keeps
  # user-requested forge access and starfleet handles onboarding. This checks exact listed
  # tool strings and a push denial, not every possible command path or live enforcement.
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
    # Validate the base first so rejection is attributable to the added legacy field.
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
    # Mission selects executable versus defused briefs; missing mission must not imply worker.
    base =
      "engineer" |> canon_path() |> YamlElixir.read_from_file!()

    {_, bad} = pop_in(base, ["spec", "brief_kind"])

    assert {:error, _} = ExJsonSchema.Validator.validate(schema, bad),
           "a cap-profile without brief_kind must be REJECTED at load (worker=executes by omission = fail-open)"
  end

  test "negative — MISSING spec.scope.allowedTools / disallowedTools rejected (F-C141: hard-required by claude_launch)",
       %{schema: schema} do
    # The launcher expects both tool lists; reject their absence at the schema boundary.
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

    # Unknown fields must not silently select defaults; sample these four object levels.
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

    # Compare the independently declared JSON and Elixir enums, not just one invalid example.
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

    # A single invalid example cannot detect widening the containment enum away from bwrap/none.
    schema_ct =
      get_in(raw, ["properties", "metadata", "properties", "containment", "enum"])

    assert schema_ct == Invariants.containment_enum(),
           "containment drift: schema #{inspect(schema_ct)} \u2260 code #{inspect(Invariants.containment_enum())}"

    # Only metadata.slot_scope is forbidden here; spec.invocation.slot_scope remains declarable.
    refute get_in(raw, ["properties", "metadata", "properties", "slot_scope"]),
           "slot_scope must no longer be declared in the schema (derived from lifetime_scope)"
  end

  test "F-C138/F-C142: canon → MCP surface reflects the two heads (onboarding=starfleet, delegation=architect)" do
    # Check role-gated names derived from catalogue data; universal MCP tools are added elsewhere.
    tools = fn role ->
      canon = role |> canon_path() |> YamlElixir.read_from_file!()

      cp = %Fleet.CapProfile{
        kind: canon["kind"],
        metadata: canon["metadata"],
        spec: canon["spec"]
      }

      Fleet.CapProfile.mcp_fleet_tools(cp)
    end

    sf = tools.("starfleet")
    assert "project_create" in sf and "project_install" in sf and "card_list" in sf
    refute "issue_create" in sf

    arch = tools.("architect")
    assert "issue_create" in arch and "issue_status" in arch and "escalation_list" in arch
    refute "project_create" in arch
    refute "project_install" in arch
  end

  test "F-05 (codex audit): no canon profile default-injects a modop whose SP contradicts its lifecycle" do
    # One-shot output/self-exit instructions can contradict a resident pod's MCP protocol.
    # This samples known phrases at the fixed business bundle path below; missing/unreadable
    # files become empty strings, so it does not prove prompt resolution or asset presence.
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
    # A runtime-supported prompt reference must also be authorable under the strict schema.
    raw =
      Application.app_dir(
        :lcars_fleet,
        "priv/catalogue-system/cap_profile/cap-profiles/architect.yaml"
      )
      |> YamlElixir.read_from_file!()

    assert :ok = Fleet.CapProfile.Schema.validate(raw, :cap_profile)

    borrowing = put_in(raw, ["spec", "systemPrompt"], "architect")
    assert :ok = Fleet.CapProfile.Schema.validate(borrowing, :cap_profile)

    typo = put_in(raw, ["spec", "systemPromt"], "architect")
    assert {:error, :invalid_schema} = Fleet.CapProfile.Schema.validate(typo, :cap_profile)
  end

  test "B-03 (catalogue L3): the canon roles carry the RIGHT capabilities (data, not magic names)" do
    cap = fn role ->
      {:ok, p} = Fleet.CapProfile.load(role)
      p
    end

    assert Fleet.CapProfile.has_capability?(cap.("architect"), :project_delegate)
    # Onboarding is outside a project; the architect delegates within its project.
    refute Fleet.CapProfile.has_capability?(cap.("architect"), :onboarder)
    assert Fleet.CapProfile.has_capability?(cap.("starfleet"), :onboarder)
    refute Fleet.CapProfile.has_capability?(cap.("starfleet"), :project_delegate)
    assert Fleet.CapProfile.has_capability?(cap.("gatekeeper"), :exception_judge)
    assert Fleet.CapProfile.has_capability?(cap.("engineer"), :producer)
    refute Fleet.CapProfile.has_capability?(cap.("engineer"), :onboarder)

    for judge <- ~w(scoper qualifier reviewer) do
      refute Fleet.CapProfile.has_capability?(cap.(judge), :onboarder)
      refute Fleet.CapProfile.has_capability?(cap.(judge), :project_delegate)
    end
  end

  describe "modop overlays are IDENTITY (a modop changes behavior via its SP bundle, never the profile)" do
    test "every canon modop profile.yaml parses to the EMPTY map" do
      # Bundled modops change prompts, not profile data. Non-empty overlays require revisiting
      # this explicit catalogue decision, even though the general composer supports merging.
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
      # The flag gates engage as well as wake; a machine-spawned pod needing a bootstrap
      # kick cannot rely on it. The assertion covers @profiles, not every bundled role.
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
