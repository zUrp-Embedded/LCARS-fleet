defmodule Fleet.CapProfileTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    prev = Application.get_env(:fleet_cap_profile, :root_dir)
    Application.put_env(:fleet_cap_profile, :root_dir, tmp_dir)
    # Restaure l'état exact : si :root_dir n'était pas set, le SUPPRIMER
    # (pas put_env(nil) — ça fuite un nil dans l'env partagé umbrella et
    # crashe les tests d'autres apps qui lisent root_dir).
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

  defp valid_profile_yaml do
    """
    apiVersion: lcars/v2.5
    kind: CapabilityProfile
    metadata:
      name: test-role
      containment: bwrap
    spec:
      scope:
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
      injects: {}
      modop_set:
        default: []
    """
  end

  defp write_role(tmp_dir, role, yaml) do
    File.write!(Path.join(tmp_dir, "#{role}.yaml"), yaml)
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
        "injects" => %{},
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
      write_role(tmp_dir, "incomplete", "apiVersion: lcars/v2.5\nkind: CapabilityProfile\n")
      assert {:error, :invalid_schema} = Fleet.CapProfile.load("incomplete")
    end

    test "falls back to archivistes/<role>.yaml", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "archivistes"))
      File.write!(Path.join([tmp_dir, "archivistes", "specialist.yaml"]), valid_profile_yaml())

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

    # R0.8-brick3 : test "rejects modop with reserved key apiVersion" retiré
    # — apiVersion n'est plus une reserved key (le champ n'existe plus).

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
      write_modop(tmp_dir, "m1", "spec:\n  lifetime_scope: pipe\n")
      write_modop(tmp_dir, "m2", "spec:\n  lifetime_scope: run\n")

      {:ok, p_a} = Fleet.CapProfile.compose("engineer", ["m1", "m2"])
      {:ok, p_b} = Fleet.CapProfile.compose("engineer", ["m2", "m1"])

      assert p_a.spec["lifetime_scope"] == "run"
      assert p_b.spec["lifetime_scope"] == "pipe"
      assert Fleet.CapProfile.sha256(p_a) != Fleet.CapProfile.sha256(p_b)
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

    # R0.8-brick3 : G24-2 (check_api_version) retiré — apiVersion n'existe
    # plus dans le struct ni dans le schema (versioning par le code v2).
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

    # G24-5 retiré : Face 2 doctrine — workers PEUVENT push si cap-profile
    # autorise via allowedTools claude CLI. L'ancien invariant qui exigeait
    # `"push"` dans git_ops_denied est obsolète. Le mécanisme baseline
    # `_baseline-git-denied.yaml` + `with_resolved_disallowed_tools/1`
    # remplace : interdit les patterns destructeurs sans bloquer push.

    test "G24-6 fails when both modops in incompatible pair are active" do
      profile =
        valid_struct()
        |> put_in([Access.key!(:spec), "modop_set"], ["a", "b"])
        |> put_in([Access.key!(:spec), "modop_incompatible"], [["a", "b"]])

      assert {:error, codes} = Fleet.CapProfile.validate(profile)
      assert :g24_6 in codes
    end

    # R0.8-brick4 : G24-7 (check_budget) retiré — pas d'API = pas de budget
    # (cf. feedback "Pas de budget dans cap-profiles"). Timeout de réponse
    # géré par Pod.monitor_timeout_ms/1 (default par lifetime_scope).

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
  # git_ops_denied_patterns/1 + with_resolved_disallowed_tools/1
  # Mécanisme catalogue→claude CLI (face 1 décision archi git, 2026-05-24)
  # ============================================================

  describe "git_ops_denied_patterns/1" do
    test "traduit chaque entrée sémantique en Bash(git X:*)" do
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

    test "retourne [] si git_ops_denied absent" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "x"},
        spec: %{"scope" => %{}}
      }

      assert Fleet.CapProfile.git_ops_denied_patterns(profile) == []
    end

    test "ignore entrées vides ou non-binaires" do
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
    test "lit _baseline-git-denied.yaml + traduit en patterns Bash(git X:*)" do
      patterns = Fleet.CapProfile.baseline_git_ops_denied_patterns()

      assert is_list(patterns)
      # Patterns intangibles attendus dans le baseline (peuvent évoluer ;
      # tests assertent un sous-ensemble canonique pour détecter régression
      # sans casser sur ajout futur).
      assert "Bash(git push --force:*)" in patterns
      assert "Bash(git reset --hard:*)" in patterns
      assert "Bash(git rebase main:*)" in patterns
    end
  end

  describe "with_resolved_disallowed_tools/1" do
    test "fusionne patterns avec disallowedTools existants (ordre préservé, sans doublons)" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "engineer"},
        spec: %{
          "scope" => %{
            "disallowedTools" => ["web_search", "code_execution"],
            # Pattern worker NON présent dans le baseline universel — assert
            # qu'il est bien ajouté sans casser le baseline.
            "git_ops_denied" => ["push some-feature-branch"]
          }
        }
      }

      resolved = Fleet.CapProfile.with_resolved_disallowed_tools(profile)
      disallowed = get_in(resolved.spec, ["scope", "disallowedTools"])

      # Existants préservés en tête, ordre.
      assert ["web_search", "code_execution" | _] = disallowed
      # Baseline universel appliqué.
      assert "Bash(git push --force:*)" in disallowed
      assert "Bash(git reset --hard:*)" in disallowed
      # Profile-spécifique appliqué.
      assert "Bash(git push some-feature-branch:*)" in disallowed
    end

    test "baseline appliqué même si profile.scope.git_ops_denied est vide" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "minimal"},
        spec: %{"scope" => %{"disallowedTools" => [], "git_ops_denied" => []}}
      }

      resolved = Fleet.CapProfile.with_resolved_disallowed_tools(profile)
      disallowed = get_in(resolved.spec, ["scope", "disallowedTools"])

      # Le baseline universel est toujours appliqué — protection intangible.
      assert "Bash(git push --force:*)" in disallowed
      assert "Bash(git reset --hard:*)" in disallowed
    end

    test "idempotent — appliquer deux fois donne le même résultat" do
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

    test "git_ops_denied absent → disallowedTools = existants + baseline universel seul" do
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

    test "git_ops_denied présent, disallowedTools absent → baseline + profile patterns" do
      profile = %Fleet.CapProfile{
        kind: "CapabilityProfile",
        metadata: %{"name" => "x"},
        # `push origin custom` n'est PAS dans le baseline (push --force /
        # -f / --force-with-lease oui, mais push simple non).
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
        member_of(~w(one-shot pipe run session-user forever))
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

  # R0.8-brick3 : property G24-2 retirée — apiVersion n'est plus dans le
  # struct, le check `check_api_version` est supprimé (le code v2 release
  # fait office de versioning, pas un champ embarqué).

  property "G24-1 violation detected when containment is unknown" do
    check all(profile <- valid_profile_struct_gen(), max_runs: 30) do
      mutated = put_in(profile.metadata["containment"], "ad-hoc")
      assert {:error, codes} = Fleet.CapProfile.validate(mutated)
      assert :g24_1 in codes
    end
  end
end
