defmodule Fleet.CapProfileTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    prev = Application.get_env(:fleet_cap_profile, :root_dir)
    Application.put_env(:fleet_cap_profile, :root_dir, tmp_dir)
    # Restore the exact prior state: if :root_dir was not set, DELETE it
    # (not put_env(nil) — that leaks a nil into the shared umbrella env and
    # crashes other apps' tests that read root_dir).
    on_exit(fn ->
      if prev,
        do: Application.put_env(:fleet_cap_profile, :root_dir, prev),
        else: Application.delete_env(:fleet_cap_profile, :root_dir)
    end)

    :ok
  end

  # ============================================================
  # Fixtures
  # ============================================================

  # Minimal in-memory profile carrying just role_index + lifetime_scope (for kill_class/1).
  defp kc_prof(role_index, lifetime) do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "r", "role_index" => role_index},
      spec: %{"invocation" => %{"lifetime_scope" => lifetime}}
    }
  end

  defp valid_profile_yaml do
    # NB: no `apiVersion` — the field was REMOVED from the model (versioning lives in the code, R0.8-brick3);
    # the strict v2.5 schema (additionalProperties:false) rejects it as an unknown field.
    """
    kind: CapabilityProfile
    metadata:
      name: test-role
      containment: bwrap
    spec:
      brief_kind: worker
      interlocutor: fleet
      scope:
        allowedTools:
          - Read
          - Grep
          - Bash
        disallowedTools:
          - web_search
          - web_fetch
          - code_execution
          - bash_code_execution
          - text_editor_code_execution
          - tool_search_internal
        git_ops_denied:
          - push
      knowledge: {}
      invocation:
        lifetime_scope: one-shot
      modop_set:
        default: []
    """
  end

  # The loader resolves by `metadata.name` (not by file name). Align `name` with `role` so that
  # `load(role)` finds the profile — fixtures carry `name: test-role` by default.
  # (If the yaml has no `name:`, it is written as-is.)
  defp write_role(tmp_dir, role, yaml) do
    aligned = String.replace(yaml, ~r/^(\s*name:).*$/m, "\\1 #{role}", global: false)
    File.write!(Path.join(tmp_dir, "#{role}.yaml"), aligned)
  end

  # G24-10..14 helpers: mutate a nested sub-field of the struct (string keys).
  defp put_invocation(struct, key, value) do
    put_in(struct, [Access.key!(:spec), "invocation", key], value)
  end

  defp put_knowledge(struct, key, value) do
    put_in(struct, [Access.key!(:spec), "knowledge", key], value)
  end

  defp write_modop(tmp_dir, name, yaml) do
    dir = Path.join([tmp_dir, "modop", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "profile.yaml"), yaml)
  end

  defp valid_struct do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "test", "containment" => "bwrap"},
      spec: %{
        "scope" => %{
          "allowedTools" => ["Read", "Grep", "Bash"],
          "disallowedTools" => [
            "web_search",
            "web_fetch",
            "code_execution",
            "bash_code_execution",
            "text_editor_code_execution",
            "tool_search_internal"
          ],
          "git_ops_denied" => ["push"]
        },
        "knowledge" => %{},
        "invocation" => %{"lifetime_scope" => "one-shot"},
        "modop_set" => %{"default" => []}
      }
    }
  end

  # ============================================================
  # load/1
  # ============================================================

  describe "load/1" do
    test "loads a valid profile", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      assert {:ok,
              %Fleet.CapProfile{
                kind: "CapabilityProfile"
              }} = Fleet.CapProfile.load("engineer")
    end

    test "returns :not_found when role file missing" do
      assert {:error, :not_found} = Fleet.CapProfile.load("ghost-role")
    end

    test "returns :invalid_schema when YAML is missing required fields", %{tmp_dir: tmp_dir} do
      # has a metadata.name (thus indexable/resolvable) but lacks containment + spec → invalid_schema
      write_role(
        tmp_dir,
        "incomplete",
        "kind: CapabilityProfile\nmetadata:\n  name: incomplete\n"
      )

      assert {:error, :invalid_schema} = Fleet.CapProfile.load("incomplete")
    end

    test "#27: metadata.name collision → {:error, :name_collision}, NOT a CaseClauseError",
         %{tmp_dir: tmp_dir} do
      # Two catalogue files carrying the SAME metadata.name = broken deploy artifact.
      # `name_index` returns {:error, :name_collision} (fail-loud, logged) — the `case` in
      # `read_role` must propagate this variant too, otherwise load/spawn crashes with an
      # opaque CaseClauseError instead of the intended tag. `list/1` already propagates it;
      # `read_role` (the load/compose path) must do the same.
      yaml =
        String.replace(valid_profile_yaml(), ~r/^(\s*name:).*$/m, "\\1 collide", global: false)

      File.write!(Path.join(tmp_dir, "dup-a.yaml"), yaml)
      File.write!(Path.join(tmp_dir, "dup-b.yaml"), yaml)

      assert {:error, :name_collision} = Fleet.CapProfile.Catalog.read_role("collide")
      # the full public path propagates the same tag (never a crash)
      assert {:error, :name_collision} = Fleet.CapProfile.load("collide")
    end

    test "F-040: non-decodable YAML in the catalogue → :invalid_schema (not :not_found)",
         %{tmp_dir: tmp_dir} do
      # Silently skipping a corrupt .yaml in `name_index` would make the role look ABSENT
      # (:not_found) instead of corrupt (:invalid_schema). A non-decodable file = broken
      # deploy artifact → fail-loud: the whole catalogue is poisoned (loading any role and
      # `list/1` both return the error) — consistent with "we don't rescue a wounded thing".
      File.write!(Path.join(tmp_dir, "broken.yaml"), "a: [b, c\n")

      assert {:error, :invalid_schema} = Fleet.CapProfile.load("whatever-role")
      assert {:error, {:invalid_yaml, _path}} = Fleet.CapProfile.list(tmp_dir)
    end

    test "resolves a profile under archivistes/ by its metadata.name", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "archivistes"))

      aligned =
        String.replace(valid_profile_yaml(), ~r/^(\s*name:).*$/m, "\\1 specialist", global: false)

      File.write!(Path.join([tmp_dir, "archivistes", "specialist.yaml"]), aligned)

      assert {:ok, %Fleet.CapProfile{}} = Fleet.CapProfile.load("specialist")
    end

    @tag regression: "F-002"
    test "returns :schema_unavailable when schema dir empty (no panic)", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      empty_schema_dir = Path.join(tmp_dir, "empty-schemas")
      File.mkdir_p!(empty_schema_dir)
      prev = Application.get_env(:fleet_cap_profile, :schema_dir)
      Application.put_env(:fleet_cap_profile, :schema_dir, empty_schema_dir)
      on_exit(fn -> Application.put_env(:fleet_cap_profile, :schema_dir, prev) end)

      assert {:error, :schema_unavailable} = Fleet.CapProfile.load("engineer")
    end

    test "R0-CAP-007: catalogue dir ABSENT → :catalogue_missing (≠ :not_found which masks a broken config)",
         %{tmp_dir: tmp_dir} do
      Application.put_env(:fleet_cap_profile, :root_dir, Path.join(tmp_dir, "does-not-exist"))
      assert {:error, :catalogue_missing} = Fleet.CapProfile.load("engineer")
    end

    test "R0-CAP-008: file without metadata.name and NOT `_`-prefixed → warning (role with lost name stays visible)",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "botched.yaml"), "kind: CapabilityProfile\nspec: {}\n")

      log = ExUnit.CaptureLog.capture_log(fn -> Fleet.CapProfile.load("engineer") end)
      assert log =~ "botched.yaml has no metadata.name"
    end

    test "R0-CAP-008: `_`-prefixed file without name → SILENT skip (deliberate fragment)", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "_baseline-x.yaml"), "kind: CapabilityProfile\nspec: {}\n")

      log = ExUnit.CaptureLog.capture_log(fn -> Fleet.CapProfile.load("engineer") end)
      refute log =~ "no metadata.name"
    end
  end

  # ============================================================
  # compose/2
  # ============================================================

  describe "compose/2" do
    test "with empty modop_set returns the base profile", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      assert {:ok, %Fleet.CapProfile{kind: "CapabilityProfile"}} =
               Fleet.CapProfile.compose("engineer", [])
    end

    test "STRUCT form composes from the loaded base — the catalogue is not re-read", %{
      tmp_dir: tmp_dir
    } do
      write_role(tmp_dir, "engineer", valid_profile_yaml())
      assert {:ok, base} = Fleet.CapProfile.load("engineer")

      # The catalogue disappears between load and compose: the epoch pinned at load must
      # still compose (the two-read shape came back :not_found here — or, live, another epoch).
      File.rm!(Path.join(tmp_dir, "engineer.yaml"))

      assert {:ok, %Fleet.CapProfile{kind: "CapabilityProfile"}} =
               Fleet.CapProfile.compose(base, [])
    end

    test "applies modop deep-merge last-wins", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      write_modop(tmp_dir, "tool-bonus", """
      spec:
        scope:
          disallowedTools:
            - tool_search_extra
      """)

      assert {:ok, profile} = Fleet.CapProfile.compose("engineer", ["tool-bonus"])
      # last-wins: list replaced, not concatenated
      assert ["tool_search_extra"] = profile.spec["scope"]["disallowedTools"]
    end

    # R0.8-brick3: test "rejects modop with reserved key apiVersion" removed
    # — apiVersion is no longer a reserved key (the field no longer exists).

    test "rejects modop overriding metadata.containment", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())
      write_modop(tmp_dir, "evil", "metadata:\n  containment: none\n")

      assert {:error, :invalid_modop} = Fleet.CapProfile.compose("engineer", ["evil"])
    end

    test "rejects modop overriding metadata.name", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())
      write_modop(tmp_dir, "evil", "metadata:\n  name: hacked\n")

      assert {:error, :invalid_modop} = Fleet.CapProfile.compose("engineer", ["evil"])
    end

    test "missing modop returns :modop_not_found", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      assert {:error, :modop_not_found} = Fleet.CapProfile.compose("engineer", ["ghost"])
    end

    test "R0-CAP-009: UNKNOWN top-level modop key (typo) → :invalid_modop (fragment lock)", %{
      tmp_dir: tmp_dir
    } do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      # `spce` instead of `spec`: the modop schema's additionalProperties:false rejects it at the fragment.
      write_modop(tmp_dir, "typo", "spce:\n  invocation:\n    model: x\n")

      assert {:error, :invalid_modop} = Fleet.CapProfile.compose("engineer", ["typo"])
    end

    test "R0-CAP-009: unknown NESTED modop field → :invalid_schema (composed backstop, SSoT)", %{
      tmp_dir: tmp_dir
    } do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      # `invocaton` (nested typo) passes the permissive fragment but the strict COMPOSED profile rejects it.
      write_modop(tmp_dir, "nested_typo", "spec:\n  invocaton:\n    model: x\n")

      assert {:error, :invalid_schema} = Fleet.CapProfile.compose("engineer", ["nested_typo"])
    end

    test "deterministic sha256 across 100 invocations (PoC-16)", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      shas =
        for _ <- 1..100 do
          {:ok, profile} = Fleet.CapProfile.compose("engineer", [])
          Fleet.CapProfile.sha256(profile)
        end

      assert shas |> Enum.uniq() |> length() == 1
    end

    test "modop_set order matters (precedence)", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      # A VALID free field (`spec.invocation.model`) demonstrates deep-merge precedence: the old
      # `spec.lifetime_scope` sat at the WRONG level (the real field is `spec.invocation.lifetime_scope`),
      # tolerated by the permissive schema — the strict v2.5 rejects it.
      write_modop(tmp_dir, "m1", "spec:\n  invocation:\n    model: model-a\n")
      write_modop(tmp_dir, "m2", "spec:\n  invocation:\n    model: model-b\n")

      {:ok, p_a} = Fleet.CapProfile.compose("engineer", ["m1", "m2"])
      {:ok, p_b} = Fleet.CapProfile.compose("engineer", ["m2", "m1"])

      assert p_a.spec["invocation"]["model"] == "model-b"
      assert p_b.spec["invocation"]["model"] == "model-a"
      assert Fleet.CapProfile.sha256(p_a) != Fleet.CapProfile.sha256(p_b)
    end

    # Confinement E (WI-E2): a non-slug modop name NEVER traverses outside modop_root.
    test "rejects modop name with traversal (../) before Path.join", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())

      # Plant an escape target reachable via `<root>/modop/../../escape/profile.yaml`.
      escape = Path.join([tmp_dir, "..", "escape"])
      File.mkdir_p!(escape)
      File.write!(Path.join(escape, "profile.yaml"), "spec:\n  lifetime_scope: pipe\n")

      # Without the slug+confinement guard, `Path.join([root, "modop", "../../escape"])` would load
      # this out-of-catalogue YAML. The guard rejects it BEFORE any FS access.
      assert {:error, :invalid_modop} =
               Fleet.CapProfile.compose("engineer", ["../../escape"])

      File.rm_rf!(escape)
    end

    test "rejects modop name with slash or empty", %{tmp_dir: tmp_dir} do
      write_role(tmp_dir, "engineer", valid_profile_yaml())
      assert {:error, :invalid_modop} = Fleet.CapProfile.compose("engineer", ["a/b"])
      assert {:error, :invalid_modop} = Fleet.CapProfile.compose("engineer", [""])
    end
  end

  # ============================================================
  # validate/1 — 9 G24 invariants
  # ============================================================

  describe "validate/1" do
    test "passes on a valid profile" do
      assert :ok = Fleet.CapProfile.validate(valid_struct())
    end

    test "G24-1 fails when containment is unknown" do
      profile = put_in(valid_struct().metadata["containment"], "ad-hoc")
      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_1 in codes
    end

    # R0.8-brick3: G24-2 (check_api_version) removed — apiVersion no longer
    # exists in the struct or the schema (versioning lives in the v2 code).
    test "G24-3 fails when kind is wrong" do
      profile = %{valid_struct() | kind: "Pod"}
      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_3 in codes
    end

    test "G24-4 fails when lifetime_scope is unknown" do
      profile = put_in(valid_struct().spec["invocation"]["lifetime_scope"], "infinite")
      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_4 in codes
    end

    # G24-5 removed: Face 2 doctrine — workers MAY push when the cap-profile
    # allows it via the claude CLI allowedTools. The old invariant requiring
    # `"push"` in git_ops_denied is obsolete. The baseline mechanism
    # `_baseline-git-denied.yaml` + `with_resolved_disallowed_tools/1`
    # replaces it: forbids destructive patterns without blocking push.

    # R13: canonical v2.5 structure — `modop_set` is a MAP
    # (default/optional/incompatible); the invariant reads the ACTIVE set
    # (`active_modops/1`: the resolve decision, declared defaults as fallback).
    test "G24-6 fails when both modops in incompatible pair are active" do
      profile =
        put_in(valid_struct(), [Access.key!(:spec), "modop_set"], %{
          "default" => ["a", "b"],
          "incompatible" => [["a", "b"]]
        })

      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_6 in codes
    end

    test "G24-6 passes when incompatible pair declared but only one modop active" do
      profile =
        put_in(valid_struct(), [Access.key!(:spec), "modop_set"], %{
          "default" => ["a"],
          "optional" => ["c"],
          "incompatible" => [["a", "b"]]
        })

      # "b" is neither in default nor optional → no conflict → g24_6 absent.
      case Fleet.CapProfile.validate(profile) do
        :ok -> :ok
        {:error, codes} -> refute :g24_6 in codes
      end
    end

    test "G24-6: two mutually exclusive OPTIONALS are a coherent catalogue — no phantom refusal" do
      # Available ≠ active: neither is in the default set and no step activated them. B-01
      # refuses their real co-activation at resolve; the profile itself must stay spawnable.
      profile =
        put_in(valid_struct(), [Access.key!(:spec), "modop_set"], %{
          "default" => [],
          "optional" => ["a", "b"],
          "incompatible" => [["a", "b"]]
        })

      case Fleet.CapProfile.validate(profile) do
        :ok -> :ok
        {:error, codes} -> refute :g24_6 in codes
      end
    end

    test "G24-6 bites on a RESOLVED co-activation (active_modops stamped by resolve)" do
      profile =
        put_in(valid_struct(), [Access.key!(:spec), "modop_set"], %{
          "default" => [],
          "optional" => ["a", "b"],
          "incompatible" => [["a", "b"]]
        })

      resolved = %{profile | active_modops: ["a", "b"]}

      assert {:error, codes} = Fleet.CapProfile.validate(resolved)
      assert :g24_6 in codes
    end

    # R0.8-brick4: G24-7 (check_budget) removed — no API = no budget in
    # cap-profiles. Response timeout is handled by Pod.monitor_timeout_ms/1
    # (default per lifetime_scope).

    test "G24-8 fails when metadata.name is empty" do
      profile = put_in(valid_struct().metadata["name"], "")
      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_8 in codes
    end

    test "G24-9 strict fails when web_search is missing from disallowedTools" do
      tools = valid_struct().spec["scope"]["disallowedTools"] -- ["web_search"]
      profile = put_in(valid_struct().spec["scope"]["disallowedTools"], tools)
      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_9_strict in codes
    end

    test "G24-9 prefix fails when no tool_search_* present" do
      tools =
        Enum.reject(
          valid_struct().spec["scope"]["disallowedTools"],
          &String.starts_with?(&1, "tool_search_")
        )

      profile = put_in(valid_struct().spec["scope"]["disallowedTools"], tools)
      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_9_prefix in codes
    end
  end

  # ============================================================
  # validate/1 — v2.5 extensions G24-10..14 (BL-022)
  # Reconciled DN↔actual: string keys, G24-12 without system_user,
  # G24-13 (liveness) outside pure validate/1, G24-14 structural only.
  # ============================================================

  describe "validate/1 — G24-10..14 (v2.5)" do
    test "valid_struct (without v2.5 fields) passes — back-compat defaults" do
      # No boot_at_start/subagent_template/host_native/monk_* → all :ok.
      assert :ok = Fleet.CapProfile.validate(valid_struct())
    end

    # --- G24-10: boot_at_start ⟹ forever ---
    test "G24-10 fails when boot_at_start: true but lifetime_scope != forever" do
      profile =
        valid_struct()
        |> put_invocation("boot_at_start", true)
        |> put_invocation("lifetime_scope", "one-shot")

      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_10 in codes
    end

    test "G24-10 passes when boot_at_start: true and lifetime_scope: forever" do
      profile =
        valid_struct()
        |> put_invocation("boot_at_start", true)
        |> put_invocation("lifetime_scope", "forever")

      assert :ok = Fleet.CapProfile.validate(profile)
    end

    test "G24-10 passes when boot_at_start absent (nil ≠ true)" do
      profile = put_invocation(valid_struct(), "lifetime_scope", "run")
      assert :ok = Fleet.CapProfile.validate(profile)
    end

    # --- G24-11: subagent_template ⟹ one-shot ---
    test "G24-11 fails when subagent_template set but lifetime_scope != one-shot" do
      profile =
        valid_struct()
        |> put_invocation("subagent_template", "implementer")
        |> put_invocation("lifetime_scope", "forever")

      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_11 in codes
    end

    test "G24-11 passes when subagent_template set and lifetime_scope: one-shot" do
      profile = put_invocation(valid_struct(), "subagent_template", "implementer")
      # valid_struct is already one-shot.
      assert :ok = Fleet.CapProfile.validate(profile)
    end

    test "G24-11 passes when subagent_template empty string (no template)" do
      profile =
        valid_struct()
        |> put_invocation("subagent_template", "")
        |> put_invocation("lifetime_scope", "forever")

      assert :ok = Fleet.CapProfile.validate(profile)
    end

    # --- G24-12: host_native ⟹ containment none (without system_user) ---
    test "G24-12 fails when host_native: true but containment != none" do
      # valid_struct.metadata.containment == "bwrap".
      profile = put_invocation(valid_struct(), "host_native", true)
      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_12 in codes
    end

    test "G24-12 passes when host_native: true and containment: none" do
      profile =
        valid_struct()
        |> put_invocation("host_native", true)
        |> put_in([Access.key!(:metadata), "containment"], "none")

      assert :ok = Fleet.CapProfile.validate(profile)
    end

    # --- G24-14: monk_registry ⟺ monk_instance pairing ---
    test "G24-14 fails when monk_registry set without monk_instance" do
      profile = put_knowledge(valid_struct(), "monk_registry", "/some/registry.yaml")
      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_14 in codes
    end

    test "G24-14 fails when monk_instance set without monk_registry" do
      profile = put_knowledge(valid_struct(), "monk_instance", "vision-doctrine")
      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_14 in codes
    end

    test "G24-14 passes when both monk_registry and monk_instance set" do
      profile =
        valid_struct()
        |> put_knowledge("monk_registry", "/some/registry.yaml")
        |> put_knowledge("monk_instance", "vision-doctrine")

      assert :ok = Fleet.CapProfile.validate(profile)
    end

    test "G24-14 passes when neither monk field set (both-or-neither)" do
      assert :ok = Fleet.CapProfile.validate(valid_struct())
    end

    test "R0-CAP-013: G24-14 treats an EMPTY string as absent (broken `x`+`\"\"` pairing → fail)" do
      # `monk_registry: "x"` + `monk_instance: ""`: a nil-only check would let this pass (`""` is
      # non-nil) → half-declared pairing. An empty/whitespace string counts as absent.
      broken =
        valid_struct()
        |> put_knowledge("monk_registry", "/some/registry.yaml")
        |> put_knowledge("monk_instance", "   ")

      assert {:error, codes} = Fleet.CapProfile.validate(broken)
      assert :g24_14 in codes

      # `""` + `""` = both absent → :ok (both-or-neither honoured)
      both_empty =
        valid_struct()
        |> put_knowledge("monk_registry", "")
        |> put_knowledge("monk_instance", "")

      assert :ok = Fleet.CapProfile.validate(both_empty)
    end
  end

  describe "from_map/1 (validated in-memory constructor — BND-001)" do
    test "schema-conformant map → {:ok, %CapProfile{}} (same validation as load)" do
      # A nominal fixture (builder) IS schema-conformant; re-pass it as a map and from_map rebuilds it.
      p = Fleet.Support.CapProfileFixture.build()
      map = %{"kind" => p.kind, "metadata" => p.metadata, "spec" => p.spec}

      assert {:ok, %Fleet.CapProfile{}} = Fleet.CapProfile.from_map(map)
    end

    test "NON-conformant map (empty spec) → {:error, :invalid_schema} — never a silently forged profile" do
      # THIS is the BND-001 hole: without from_map this shape gets hand-built as `%CapProfile{spec: %{}}`,
      # schema short-circuited. The constructor REJECTS it (same verdict as load), it does not normalize it.
      raw = %{
        "kind" => "CapabilityProfile",
        "metadata" => %{"name" => "x", "containment" => "bwrap"},
        "spec" => %{}
      }

      assert {:error, :invalid_schema} = Fleet.CapProfile.from_map(raw)
    end

    test "from_map!/1 raises on a non-conformant map (bad fixture = raise, not a partial profile)" do
      assert_raise ArgumentError, ~r/not schema-conformant/, fn ->
        Fleet.CapProfile.from_map!(%{"kind" => "x", "metadata" => %{}, "spec" => %{}})
      end
    end

    test "support builder: canonical profile + override → schema-conformant, override applied" do
      profile =
        Fleet.Support.CapProfileFixture.build(%{"metadata" => %{"name" => "engineer-test"}})

      assert Fleet.CapProfile.name(profile) == "engineer-test"
      assert :ok = Fleet.CapProfile.validate(profile)
    end
  end

  # ============================================================
  # git_ops_denied_patterns/1 + with_resolved_disallowed_tools/1
  # Catalogue→claude CLI mechanism (face 1 of the git architecture decision)
  # ============================================================

  describe "wake_send_keys?/1" do
    # 2026-07-19: false = flag-only pod (the kick loop never types into its terminal — set on
    # the architect, interactive human session). Absent/nil-tolerant: default is TRUE.
    test "false in spec.invocation → fallback denied" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "architect"},
        spec: %{"invocation" => %{"wake_send_keys" => false}}
      }

      refute Fleet.CapProfile.wake_send_keys?(profile)
    end

    test "absent → authorized (default true)" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer"},
        spec: %{"invocation" => %{"lifetime_scope" => "pipe"}}
      }

      assert Fleet.CapProfile.wake_send_keys?(profile)
    end

    test "nil / non-profile input (test-stub pod data) → authorized" do
      assert Fleet.CapProfile.wake_send_keys?(nil)
      assert Fleet.CapProfile.wake_send_keys?(%{})
    end
  end

  describe "remote_control?/1" do
    # Gates the Desktop-slot capture (a no-RC pod never registers → nothing to capture).
    test "false in spec.invocation → invisible (no capture)" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "qualifier"},
        spec: %{"invocation" => %{"remote_control" => false}}
      }

      refute Fleet.CapProfile.remote_control?(profile)
    end

    test "absent → visible (default true)" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "architect"},
        spec: %{"invocation" => %{"lifetime_scope" => "forever"}}
      }

      assert Fleet.CapProfile.remote_control?(profile)
    end

    test "nil / non-profile input → visible (safe default)" do
      assert Fleet.CapProfile.remote_control?(nil)
      assert Fleet.CapProfile.remote_control?(%{})
    end
  end

  describe "kill_class/1 — the <X> nibble (lifecycle/kill), derived (2026-07-19)" do
    test "starfleet (role_index 0) → 0 (never killed), whatever the lifetime" do
      assert Fleet.CapProfile.kill_class(kc_prof(0, "forever")) == 0
    end

    test "one-shot judge (qualifier/reviewer/consultant) → 2 (spawn-dead, reaped)" do
      assert Fleet.CapProfile.kill_class(kc_prof(4, "one-shot")) == 2
      assert Fleet.CapProfile.kill_class(kc_prof(6, "one-shot")) == 2
    end

    test "persistent non-starfleet (arch forever, gatekeeper/eng pipe) → 1 (kill-safe, resumable)" do
      assert Fleet.CapProfile.kill_class(kc_prof(1, "forever")) == 1
      assert Fleet.CapProfile.kill_class(kc_prof(2, "pipe")) == 1
      assert Fleet.CapProfile.kill_class(kc_prof(3, "pipe")) == 1
    end
  end

  describe "git_ops_denied_patterns/1" do
    test "translates each semantic entry into Bash(git X:*)" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer"},
        spec: %{"scope" => %{"git_ops_denied" => ["push --force", "reset --hard", "rebase main"]}}
      }

      assert Fleet.CapProfile.git_ops_denied_patterns(profile) == [
               "Bash(git push --force:*)",
               "Bash(git reset --hard:*)",
               "Bash(git rebase main:*)"
             ]
    end

    test "returns [] when git_ops_denied absent" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "x"},
        spec: %{"scope" => %{}}
      }

      assert Fleet.CapProfile.git_ops_denied_patterns(profile) == []
    end

    test "ignores empty or non-binary entries" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "x"},
        spec: %{"scope" => %{"git_ops_denied" => ["push", "", nil, 42, "reset"]}}
      }

      assert Fleet.CapProfile.git_ops_denied_patterns(profile) == [
               "Bash(git push:*)",
               "Bash(git reset:*)"
             ]
    end
  end

  describe "baseline_git_ops_denied_patterns/0" do
    test "reads _baseline-git-denied.yaml + translates into Bash(git X:*) patterns" do
      patterns = Fleet.CapProfile.baseline_git_ops_denied_patterns()

      assert is_list(patterns)
      # Intangible patterns expected in the baseline (may evolve;
      # tests assert a canonical subset to catch regression without
      # breaking on future additions).
      assert "Bash(git push --force:*)" in patterns
      assert "Bash(git reset --hard:*)" in patterns
      assert "Bash(git rebase main:*)" in patterns
    end
  end

  describe "with_resolved_disallowed_tools/1" do
    test "merges patterns with existing disallowedTools (order preserved, no duplicates)" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer"},
        spec: %{
          "scope" => %{
            "disallowedTools" => ["web_search", "code_execution"],
            # Worker pattern NOT present in the universal baseline — assert
            # it gets added without breaking the baseline.
            "git_ops_denied" => ["push some-feature-branch"]
          }
        }
      }

      resolved = Fleet.CapProfile.with_resolved_disallowed_tools(profile)
      disallowed = get_in(resolved.spec, ["scope", "disallowedTools"])

      # Existing entries preserved at the head, in order.
      assert ["web_search", "code_execution" | _] = disallowed
      # Universal baseline applied.
      assert "Bash(git push --force:*)" in disallowed
      assert "Bash(git reset --hard:*)" in disallowed
      # Profile-specific entry applied.
      assert "Bash(git push some-feature-branch:*)" in disallowed
    end

    test "baseline applied even when profile.scope.git_ops_denied is empty" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "minimal"},
        spec: %{"scope" => %{"disallowedTools" => [], "git_ops_denied" => []}}
      }

      resolved = Fleet.CapProfile.with_resolved_disallowed_tools(profile)
      disallowed = get_in(resolved.spec, ["scope", "disallowedTools"])

      # The universal baseline is always applied — intangible protection.
      assert "Bash(git push --force:*)" in disallowed
      assert "Bash(git reset --hard:*)" in disallowed
    end

    test "idempotent — applying twice yields the same result" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer"},
        spec: %{
          "scope" => %{
            "disallowedTools" => ["web_search"],
            "git_ops_denied" => ["push --force"]
          }
        }
      }

      once = Fleet.CapProfile.with_resolved_disallowed_tools(profile)
      twice = Fleet.CapProfile.with_resolved_disallowed_tools(once)

      assert once == twice
    end

    test "git_ops_denied absent → disallowedTools = existing + universal baseline only" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "x"},
        spec: %{"scope" => %{"disallowedTools" => ["web_search"]}}
      }

      resolved = Fleet.CapProfile.with_resolved_disallowed_tools(profile)
      disallowed = get_in(resolved.spec, ["scope", "disallowedTools"])

      assert ["web_search" | _baseline] = disallowed
      assert "Bash(git push --force:*)" in disallowed
    end

    test "git_ops_denied present, disallowedTools absent → baseline + profile patterns" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "x"},
        # `push origin custom` is NOT in the baseline (push --force /
        # -f / --force-with-lease are, plain push is not).
        spec: %{"scope" => %{"git_ops_denied" => ["push origin custom"]}}
      }

      resolved = Fleet.CapProfile.with_resolved_disallowed_tools(profile)
      disallowed = get_in(resolved.spec, ["scope", "disallowedTools"])

      assert "Bash(git push --force:*)" in disallowed
      assert "Bash(git push origin custom:*)" in disallowed
    end
  end

  # ============================================================
  # sha256/1 — canonical encoder properties
  # ============================================================

  describe "sha256/1" do
    test "stable across 100 invocations on the same map" do
      map = %{"a" => 1, "b" => %{"c" => [1, 2], "d" => "x"}, "e" => true}
      shas = for _ <- 1..100, do: Fleet.CapProfile.sha256(map)
      assert shas |> Enum.uniq() |> length() == 1
    end

    test "is invariant to map key insertion order" do
      m1 = %{"a" => 1, "b" => 2, "c" => 3, "d" => 4, "e" => 5}
      m2 = %{"e" => 5, "c" => 3, "a" => 1, "d" => 4, "b" => 2}
      assert Fleet.CapProfile.sha256(m1) == Fleet.CapProfile.sha256(m2)
    end

    test "differs when content differs" do
      assert Fleet.CapProfile.sha256(%{"a" => 1}) != Fleet.CapProfile.sha256(%{"a" => 2})
    end

    test "R0-CAP-014: key collision after stringification → raise (unambiguous hash)" do
      # `:k` and `"k"` both stringify to "k" → ambiguous canonical form → fail-loud refusal
      # rather than an unstable hash depending on Map iteration order.
      assert_raise ArgumentError, ~r/key collision/, fn ->
        Fleet.CapProfile.CanonicalJson.encode(%{:k => 1, "k" => 2})
      end
    end
  end

  # ============================================================
  # Role catalogue → session_id: role_index / protected? / fleet_level? / catalogued?
  # (the source of the WHAT lives here, not in Fleet.Spawner.SessionId — the encoder does not catalogue)
  # ============================================================

  describe "catalogue accessors (role_index/protected?/fleet_level?/catalogued?)" do
    defp role_struct(metadata),
      do: %Fleet.CapProfile{kind: "CapabilityProfile", metadata: metadata, spec: %{}}

    test "role_index/1 reads metadata.role_index integer 0..15, raises when absent/non-integer/OUT-OF-BOUNDS (R0-CAP-006)" do
      assert Fleet.CapProfile.role_index(role_struct(%{"role_index" => 3})) == 3
      assert Fleet.CapProfile.role_index(role_struct(%{"role_index" => 0})) == 0
      assert Fleet.CapProfile.role_index(role_struct(%{"role_index" => 15})) == 15

      # absent, non-integer, AND outside the nibble's 4 bits (16, -1) → raise (invalid nibble)
      for bad <- [
            %{"name" => "ad-hoc"},
            %{"role_index" => "3"},
            %{"role_index" => 16},
            %{"role_index" => -1}
          ] do
        assert_raise ArgumentError, fn -> Fleet.CapProfile.role_index(role_struct(bad)) end
      end
    end

    test "R0-CAP-005: with_project stringifies keys (preserves the deep-string-keys invariant)" do
      cap = valid_struct()

      # ATOM-keyed project (what a brief/dispatch may pass) → must come out with STRING keys
      eff = Fleet.CapProfile.with_project(cap, %{repo_path: "/r", nested: %{a: 1}})

      assert eff.spec["project"] == %{"repo_path" => "/r", "nested" => %{"a" => 1}}
    end

    test "protected?/1 + fleet_level?/1 are GONE (reorg 2026-07-19 — collapsed into role_index 0)" do
      # Both bits died when every non-starfleet role went per-project: the kill tier is kill_class/1,
      # the fleet-scope (repo 0000) is `role_index == 0` at the mint. The schema rejects the fields.
      refute function_exported?(Fleet.CapProfile, :protected?, 1)
      refute function_exported?(Fleet.CapProfile, :fleet_level?, 1)
    end

    test "catalogued?/1: true iff an integer role_index is present (presence check WITHOUT raise)" do
      assert Fleet.CapProfile.catalogued?(role_struct(%{"role_index" => 0}))
      refute Fleet.CapProfile.catalogued?(role_struct(%{"name" => "ad-hoc"}))
      refute Fleet.CapProfile.catalogued?(role_struct(%{"role_index" => "0"}))

      # consistency with role_index/1: an index OUTSIDE 0..15 is not catalogued (otherwise
      # catalogued?=true but role_index/1 raises → broken contract).
      refute Fleet.CapProfile.catalogued?(role_struct(%{"role_index" => 16}))
    end

    test "slot_scope/1 DERIVES from lifetime_scope: one-shot→instance, context-long→project" do
      life = fn lt ->
        %Fleet.CapProfile{
          kind: "CapabilityProfile",
          metadata: %{"name" => "x"},
          spec: %{"invocation" => %{"lifetime_scope" => lt}}
        }
      end

      # one-shot = cold, independent → fan-out → instance
      assert Fleet.CapProfile.slot_scope(life.("one-shot")) == "instance"

      # context-long (pipe/run/forever) = one instance keeping its context → unique/serialized → project
      assert Fleet.CapProfile.slot_scope(life.("pipe")) == "project"
      assert Fleet.CapProfile.slot_scope(life.("run")) == "project"
      assert Fleet.CapProfile.slot_scope(life.("forever")) == "project"

      # lifetime absent (empty spec) → default one-shot → instance: the SAFE failure mode
      # (ephemeral/fan-out, never a shared Desktop slot claimed by mistake).
      assert Fleet.CapProfile.slot_scope(role_struct(%{"name" => "ad-hoc"})) == "instance"
    end
  end

  # ============================================================
  # Property-based generators
  # ============================================================

  defp leaf_gen do
    one_of([
      integer(),
      boolean(),
      string(:alphanumeric, max_length: 12)
    ])
  end

  defp nested_value_gen(0), do: leaf_gen()

  defp nested_value_gen(depth) when depth > 0 do
    one_of([
      leaf_gen(),
      list_of(leaf_gen(), max_length: 4),
      map_of(
        string(:alphanumeric, min_length: 1, max_length: 4),
        nested_value_gen(depth - 1),
        max_length: 4
      )
    ])
  end

  defp nested_map_gen do
    map_of(
      string(:alphanumeric, min_length: 1, max_length: 6),
      nested_value_gen(2),
      max_length: 6
    )
  end

  defp valid_profile_struct_gen do
    map(
      tuple({
        string(:alphanumeric, min_length: 1, max_length: 12),
        member_of(~w(bwrap none)),
        member_of(~w(one-shot pipe run forever))
      }),
      fn {name, containment, lifetime} ->
        %Fleet.CapProfile{
          kind: "CapabilityProfile",
          metadata: %{"name" => name, "containment" => containment},
          spec: %{
            "scope" => %{
              "disallowedTools" => [
                "web_search",
                "web_fetch",
                "code_execution",
                "bash_code_execution",
                "text_editor_code_execution",
                "tool_search_internal"
              ],
              "git_ops_denied" => ["push"]
            },
            "knowledge" => %{},
            "invocation" => %{"lifetime_scope" => lifetime},
            "injects" => %{},
            "modop_set" => %{"default" => []}
          }
        }
      end
    )
  end

  # ============================================================
  # Property-based — sha256 stability + canonical encoder
  # ============================================================

  property "sha256 is stable across two consecutive calls on flat maps" do
    check all(
            map <-
              map_of(
                string(:alphanumeric, min_length: 1, max_length: 8),
                leaf_gen(),
                max_length: 10
              )
          ) do
      assert Fleet.CapProfile.sha256(map) == Fleet.CapProfile.sha256(map)
    end
  end

  property "sha256 is stable on nested maps (recursive canonical encoder)" do
    check all(map <- nested_map_gen()) do
      assert Fleet.CapProfile.sha256(map) == Fleet.CapProfile.sha256(map)
    end
  end

  property "sha256 is invariant to map key insertion order" do
    # Use map_of (keys unique by construction) and shuffle entries, otherwise
    # list_of({k, v}) + Map.new can duplicate keys with last-wins dedup.
    check all(
            map <-
              map_of(
                string(:alphanumeric, min_length: 1, max_length: 6),
                integer(),
                min_length: 1,
                max_length: 10
              )
          ) do
      pairs = Map.to_list(map)
      m1 = Map.new(pairs)
      m2 = Map.new(Enum.shuffle(pairs))
      assert Fleet.CapProfile.sha256(m1) == Fleet.CapProfile.sha256(m2)
    end
  end

  # ============================================================
  # Property-based — G24 conformance on random valid profiles
  # ============================================================

  property "validate/1 returns :ok on randomly generated valid profiles" do
    check all(profile <- valid_profile_struct_gen(), max_runs: 50) do
      assert :ok = Fleet.CapProfile.validate(profile)
    end
  end

  # R0.8-brick3: G24-2 property removed — apiVersion is no longer in the
  # struct, the `check_api_version` check is gone (the v2 release code
  # serves as versioning, not an embedded field).

  property "G24-1 violation detected when containment is unknown" do
    check all(profile <- valid_profile_struct_gen(), max_runs: 30) do
      mutated = put_in(profile.metadata["containment"], "ad-hoc")
      assert {:error, codes} = Fleet.CapProfile.validate(mutated)
      assert :g24_1 in codes
    end
  end

  describe "mcp_fleet_tools/1 — F-C138 (MCP surface derived from the canon, SSOT)" do
    defp cp_scope(tools) do
      %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "r", "containment" => "bwrap"},
        spec: %{"brief_kind" => "worker", "scope" => %{"allowedTools" => tools}}
      }
    end

    test "extracts mcp__fleet__ entries from allowedTools, prefix stripped (order preserved)" do
      cp = cp_scope(["Read", "mcp__fleet__create_issue", "Bash", "mcp__fleet__import_project"])
      assert Fleet.CapProfile.mcp_fleet_tools(cp) == ["create_issue", "import_project"]
    end

    test "no mcp__fleet__ (judge role: Read/Bash/… only) → []" do
      assert Fleet.CapProfile.mcp_fleet_tools(cp_scope(["Read", "Bash", "ToolSearch"])) == []
    end

    test "allowedTools/scope absent → [] (no crash)" do
      bare = %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}
      assert Fleet.CapProfile.mcp_fleet_tools(bare) == []
    end
  end

  describe "default_modops/1 (F-C146/PORT — modop overlays applied at spawn)" do
    defp cp_with_spec(spec),
      do: %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: spec}

    test "spec with modop_set.default (list) → the overlay list" do
      cp = cp_with_spec(%{"modop_set" => %{"default" => ["fire-mode", "tdd"]}})
      assert ["fire-mode", "tdd"] = Fleet.CapProfile.default_modops(cp)
    end

    test "modop_set absent → [] (role without overlay)" do
      assert [] = Fleet.CapProfile.default_modops(cp_with_spec(%{}))
    end

    test "MALFORMED modop_set (list instead of a map, or non-list default) → [] (defensive, no spawn crash)" do
      assert [] = Fleet.CapProfile.default_modops(cp_with_spec(%{"modop_set" => ["default"]}))

      assert [] =
               Fleet.CapProfile.default_modops(
                 cp_with_spec(%{"modop_set" => %{"default" => "x"}})
               )
    end
  end

  describe "has_capability?/2 (catalogue chantier L3, B-03 — gates resolve a capability, not a name)" do
    defp cp_caps(caps),
      do: %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{},
        spec: %{"capabilities" => caps}
      }

    test "declared capability → true (atom or string)" do
      cp = cp_caps(["onboarder", "project_delegate"])
      assert Fleet.CapProfile.has_capability?(cp, :onboarder)
      assert Fleet.CapProfile.has_capability?(cp, "project_delegate")
      refute Fleet.CapProfile.has_capability?(cp, :producer)
    end

    test "absent/malformed capabilities → false (fail-closed for a gate)" do
      refute Fleet.CapProfile.has_capability?(
               %Fleet.CapProfile{kind: "x", metadata: %{}, spec: %{}},
               :onboarder
             )

      refute Fleet.CapProfile.has_capability?(cp_caps("not-a-list"), :onboarder)
    end

    # NB: "the canon roles carry the RIGHT capabilities" lives in the conformance test (loads the
    # REAL canon; this file redirects the catalogue to a tmp_dir).
  end

  describe "resolve/3 (catalogue chantier L1a — the single launch-site authority)" do
    # A loader that records what `compose` was called with, so we prove resolve composes
    # `default_modops(base) ++ extra` — the whole point (no divergence across launch sites).
    defmodule RecordingLoader do
      def load("engineer"),
        do:
          {:ok,
           %Fleet.CapProfile{
             kind: "CapabilityProfile",
             metadata: %{"name" => "engineer"},
             spec: %{
               "modop_set" => %{"default" => ["rubber-duck"], "optional" => ["tdd"]},
               "invocation" => %{"lifetime_scope" => "pipe"}
             }
           }}

      # The seam receives the loaded BASE (same epoch as the guard's checks), never the
      # role name — a name would mean a second catalogue read.
      def compose(%Fleet.CapProfile{} = base, modops) do
        send(self(), {:composed, base, modops})

        {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: base.metadata, spec: %{}}}
      end
    end

    # A stub loader WITHOUT compose/2 (the common dispatch-test shape) → resolve returns the base.
    defmodule LoadOnlyLoader do
      def load("engineer"),
        do: {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}}

      def load(_), do: {:error, :not_found}
    end

    test "composes default modops (no extra)" do
      assert {:ok, _} = Fleet.CapProfile.resolve(RecordingLoader, "engineer")

      assert_received {:composed, %Fleet.CapProfile{metadata: %{"name" => "engineer"}},
                       ["rubber-duck"]}
    end

    test "composes default ++ extra step-modops (order preserved)" do
      assert {:ok, _} = Fleet.CapProfile.resolve(RecordingLoader, "engineer", ["tdd"])

      assert_received {:composed, %Fleet.CapProfile{metadata: %{"name" => "engineer"}},
                       ["rubber-duck", "tdd"]}
    end

    # THE regression this closes. `compose/2` returns a profile that no longer says WHICH modops were
    # asked for — here it returns `spec: %{}`, so `default_modops/1` of the RESULT is `[]`. The spawn
    # path used to re-derive the SP's modop list from that result, so a step's optional modop was
    # validated by the B-01 guard above and then silently never reached `SPBuilder.compose`.
    test "the ACTIVE modops survive the composition (this is what reaches the pod's system prompt)" do
      assert {:ok, profile} = Fleet.CapProfile.resolve(RecordingLoader, "engineer", ["tdd"])

      assert Fleet.CapProfile.active_modops(profile) == ["rubber-duck", "tdd"]

      # Same profile, re-derived the old way: the step's `tdd` is gone — and so was its `sp.md`.
      assert Fleet.CapProfile.default_modops(profile) == []
    end

    test "a profile that never went through resolve/3 falls back to the role's declared defaults" do
      assert {:ok, base} = RecordingLoader.load("engineer")
      assert base.active_modops == nil
      assert Fleet.CapProfile.active_modops(base) == ["rubber-duck"]
    end

    test "loader without compose/2 (test stub, no overlays) → the base IS the resolved profile" do
      assert {:ok, %Fleet.CapProfile{}} = Fleet.CapProfile.resolve(LoadOnlyLoader, "engineer")
      refute_received {:composed, _, _}
    end

    test "load error propagates (never a half-resolved profile)" do
      assert {:error, :not_found} = Fleet.CapProfile.resolve(LoadOnlyLoader, "ghost")
    end

    # B-01 guard: a step can only activate a modop the ROLE declares in its `optional`.
    test "extra modop IN the role's optional → allowed (engineer + tdd)" do
      assert {:ok, _} = Fleet.CapProfile.resolve(RecordingLoader, "engineer", ["tdd"])

      assert_received {:composed, %Fleet.CapProfile{metadata: %{"name" => "engineer"}},
                       ["rubber-duck", "tdd"]}
    end

    test "extra modop OUTSIDE the role's optional → refused (no silent role-mixing)" do
      assert {:error, {:modops_not_in_optional, ["evil"]}} =
               Fleet.CapProfile.resolve(RecordingLoader, "engineer", ["evil"])

      refute_received {:composed, _, _}
    end

    defmodule IncompatibleLoader do
      def load("x"),
        do:
          {:ok,
           %Fleet.CapProfile{
             kind: "CapabilityProfile",
             metadata: %{},
             spec: %{
               "modop_set" => %{
                 "default" => ["a"],
                 "optional" => ["b"],
                 "incompatible" => [["a", "b"]]
               }
             }
           }}

      def compose(_role, _modops),
        do: {:ok, %Fleet.CapProfile{kind: "x", metadata: %{}, spec: %{}}}
    end

    test "activating an incompatible pair (default a + optional b, a⊥b) → refused" do
      assert {:error, {:modops_incompatible, ["a", "b"]}} =
               Fleet.CapProfile.resolve(IncompatibleLoader, "x", ["b"])
    end
  end

  describe "name_from_request/1 — the shared admin-spawn name parser" do
    test "cap_profile_name takes precedence over role" do
      assert Fleet.CapProfile.name_from_request(%{
               "cap_profile_name" => "engineer",
               "role" => "reviewer"
             }) == "engineer"
    end

    test "role is the fallback when cap_profile_name is absent" do
      assert Fleet.CapProfile.name_from_request(%{"role" => "reviewer"}) == "reviewer"
    end

    test "a blank cap_profile_name never masks a valid role (the truthy \"\" trap)" do
      assert Fleet.CapProfile.name_from_request(%{"cap_profile_name" => "", "role" => "reviewer"}) ==
               "reviewer"
    end

    test "no usable name (blank/nil/absent) → nil" do
      assert Fleet.CapProfile.name_from_request(%{"cap_profile_name" => "", "role" => nil}) == nil
      assert Fleet.CapProfile.name_from_request(%{}) == nil
    end
  end
end
