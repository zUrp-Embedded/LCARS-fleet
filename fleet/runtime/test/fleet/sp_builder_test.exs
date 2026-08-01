defmodule Fleet.SPBuilderTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  doctest Fleet.SPBuilder

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    sp_role_root = Path.join(tmp_dir, "cap-profiles")
    modop_root = Path.join(tmp_dir, "modop")
    File.mkdir_p!(sp_role_root)
    File.mkdir_p!(modop_root)

    prev_sp = Application.get_env(:fleet_sp_builder, :sp_role_root)
    prev_mod = Application.get_env(:fleet_sp_builder, :modop_root)

    Application.put_env(:fleet_sp_builder, :sp_role_root, sp_role_root)
    Application.put_env(:fleet_sp_builder, :modop_root, modop_root)

    on_exit(fn ->
      Application.put_env(:fleet_sp_builder, :sp_role_root, prev_sp)
      Application.put_env(:fleet_sp_builder, :modop_root, prev_mod)
    end)

    {:ok, sp_role_root: sp_role_root, modop_root: modop_root}
  end

  # ============================================================
  # Fixtures
  # ============================================================

  defp valid_cap_profile(extra_spec \\ %{}) do
    spec =
      Map.merge(
        %{
          "systemPrompt" => "engineer-role.md",
          "scope" => %{
            "disallowedTools" => ["web_search", "tool_search_internal"],
            "git_ops_denied" => ["push"]
          },
          "knowledge" => %{"skills" => ["memory-query", "loop"]},
          # R12: lifetime_scope nested under invocation (v2.5 schema).
          "invocation" => %{"lifetime_scope" => "one-shot"},
          "injects" => %{},
          "budget" => %{"maxUsd" => 1.0, "maxDurationSec" => 600},
          # modop_set = MAP (v2.5 schema: default/optional/incompatible).
          "modop_set" => %{"default" => []}
        },
        extra_spec
      )

    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer", "containment" => "bwrap"},
      spec: spec
    }
  end

  defp write_sp_role(sp_role_root, name, content) do
    File.write!(Path.join(sp_role_root, name), content)
  end

  defp write_modop_sp(modop_root, name, content) do
    dir = Path.join(modop_root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "sp.md"), content)
  end

  # ============================================================
  # compose/3
  # ============================================================

  describe "compose/3" do
    test "composes SP from cap-profile with no modop bundles", %{sp_role_root: sp_root} do
      write_sp_role(sp_root, "engineer-role.md", "# Engineer role base SP\n\nDoctrine.")

      assert {:ok,
              %{
                sp_md: sp_md,
                stable_sha256: sha,
                metadata: %{modop_bundles_used: []}
              }} = Fleet.SPBuilder.compose(valid_cap_profile(), [], pod_id: "p-1", job_id: "j-1")

      assert sp_md =~ "Engineer role base SP"
      assert is_binary(sha) and byte_size(sha) == 64
    end

    test "composes SP with modop bundles in declared order", %{
      sp_role_root: sp_root,
      modop_root: mop_root
    } do
      write_sp_role(sp_root, "engineer-role.md", "# Role\n")
      write_modop_sp(mop_root, "fire-mode", "# fire-mode discipline")
      write_modop_sp(mop_root, "rubber-duck", "# rubber-duck discipline")

      assert {:ok, %{sp_md: sp_md}} =
               Fleet.SPBuilder.compose(valid_cap_profile(), ["fire-mode", "rubber-duck"])

      assert sp_md =~ "modop:fire-mode"
      assert sp_md =~ "modop:rubber-duck"

      fire_idx = sp_md |> :binary.match("modop:fire-mode") |> elem(0)
      duck_idx = sp_md |> :binary.match("modop:rubber-duck") |> elem(0)
      assert fire_idx < duck_idx
    end

    test "returns :modop_bundle_missing when a modop sp.md is absent", %{sp_role_root: sp_root} do
      write_sp_role(sp_root, "engineer-role.md", "# Role")

      assert {:error, {:modop_bundle_missing, "ghost"}} =
               Fleet.SPBuilder.compose(valid_cap_profile(), ["ghost"])
    end

    test "returns :sp_role_path_missing when role base file is absent" do
      assert {:error, {:sp_role_path_missing, _path}} =
               Fleet.SPBuilder.compose(valid_cap_profile(), [])
    end

    test "no role base when systemPrompt is nil" do
      profile = valid_cap_profile(%{"systemPrompt" => nil})
      assert {:ok, %{sp_md: sp_md}} = Fleet.SPBuilder.compose(profile, [])
      refute sp_md =~ "Role base"
    end

    test "R1-04: malformed load-bearing opts → {:error, {:bad_opt, _}} (parse at the edge, no raise)" do
      # A non-list `preloaded_paths` would crash the `++`; a non-DateTime `spawned_at` would
      # crash `DateTime.to_iso8601`. Bounded into a typed error.
      assert {:error, {:bad_opt, {:preloaded_paths, _}}} =
               Fleet.SPBuilder.compose(valid_cap_profile(), [], preloaded_paths: "/not/a/list")

      assert {:error, {:bad_opt, {:preloaded_paths, _}}} =
               Fleet.SPBuilder.compose(valid_cap_profile(), [], preloaded_paths: [42])

      assert {:error, {:bad_opt, {:spawned_at, _}}} =
               Fleet.SPBuilder.compose(valid_cap_profile(), [], spawned_at: "2030-01-01")
    end

    test "R1-01: systemPrompt with traversal (`../`) → {:error, {:sp_role_path_escape, _}} (confined)" do
      profile = valid_cap_profile(%{"systemPrompt" => "../../../etc/passwd"})
      assert {:error, {:sp_role_path_escape, _}} = Fleet.SPBuilder.compose(profile, [])
    end

    test "R1-01: systemPrompt with null byte → {:error, {:sp_role_path_unsafe, _}} (no raise)" do
      profile = valid_cap_profile(%{"systemPrompt" => "role\0.md"})
      assert {:error, {:sp_role_path_unsafe, _}} = Fleet.SPBuilder.compose(profile, [])
    end

    test "R1-02/03: modop bundle with traversal (`../`) → {:error, {:modop_bundle_unsafe, _}} (confined_join)" do
      # systemPrompt=nil → empty sp_role_base, isolating the modop confinement.
      profile = valid_cap_profile(%{"systemPrompt" => nil})

      assert {:error, {:modop_bundle_unsafe, {"../evil", _}}} =
               Fleet.SPBuilder.compose(profile, ["../evil"])
    end

    test "R1-29: a non-slug skill name (traversal) → {:error, {:skills_unsafe, _}}", %{
      sp_role_root: root
    } do
      # `root` exists (dir) → we get past the File.dir? guard; "../../etc" is rejected BEFORE File.exists?.
      profile = valid_cap_profile(%{"knowledge" => %{"skills" => ["../../etc", "loop"]}})

      assert {:error, {:skills_unsafe, ["../../etc"]}} =
               Fleet.SPBuilder.filter_skills(profile, root)
    end

    test "modop_root has a DEFAULT (fleet_cap_profile/modop-bundles): modop without explicit config → composed (F-C146/PORT)" do
      # EXERCISES the runtime DEFAULT: remove the override → modop_root unconfigured → default
      # app_dir(:lcars_fleet, "priv/catalogue/cap_profile/canon/modop-bundles") (where the bundles live).
      # `fire-mode` exists there → composed. No :modop_root_unconfigured: the PORT wired the
      # default, like sp_role_root.
      #
      # SCOPE of this proof, since the default is easy to over-read: it shows that `SPBuilder.compose`
      # RESOLVES its bundle root without an explicit config. It does NOT show that a step's modops
      # reach a pod — this calls `compose` DIRECTLY with a list, while the spawn path is
      # `CapProfile.resolve/3` → `Pod`, which re-derives the list from `default_modops/1` and drops
      # any step-selected optional modop on the way (see the KNOWN GAP note on the B-01 guard in
      # `Fleet.CapProfile`). "The root resolves" and "the overlay reaches the pod" are two claims;
      # only the first is tested here.
      Application.delete_env(:fleet_sp_builder, :modop_root)
      profile = valid_cap_profile(%{"systemPrompt" => nil})

      assert {:ok, %{sp_md: sp_md, metadata: %{modop_bundles_used: ["fire-mode"]}}} =
               Fleet.SPBuilder.compose(profile, ["fire-mode"])

      # The fire-mode modop's SP fragment is indeed INJECTED into the system-prompt.
      assert sp_md =~ "fire-mode"
    end

    test "subagent_template (F-C147/PORT): the SP fragment is injected; missing file → fail-loud" do
      # reviewer→code-quality-reviewer: subagent-code-quality-reviewer.md exists in the canon (default root
      # = app_dir(:lcars_fleet, "priv/catalogue/cap_profile/canon/subagent-templates"), not overridden by the setup).
      profile =
        valid_cap_profile(%{
          "systemPrompt" => nil,
          "invocation" => %{
            "lifetime_scope" => "one-shot",
            "subagent_template" => "code-quality-reviewer"
          }
        })

      assert {:ok, %{sp_md: sp_md}} = Fleet.SPBuilder.compose(profile, [])
      assert sp_md =~ "subagent-template:code-quality-reviewer"
      assert sp_md =~ "code-quality-reviewer"

      # Declared but file absent → fail-loud (the pod does not launch on a half-composed SP).
      bad =
        valid_cap_profile(%{
          "systemPrompt" => nil,
          "invocation" => %{"subagent_template" => "inexistant-xyz"}
        })

      assert {:error, {:subagent_template_missing, "inexistant-xyz"}} =
               Fleet.SPBuilder.compose(bad, [])
    end

    test "preloaded_paths section is included when given", %{sp_role_root: sp_root} do
      write_sp_role(sp_root, "engineer-role.md", "# Role")

      paths = ["/tmp/preloaded-1.md", "/tmp/preloaded-2.md"]

      assert {:ok, %{sp_md: sp_md}} =
               Fleet.SPBuilder.compose(valid_cap_profile(), [], preloaded_paths: paths)

      assert sp_md =~ "Ressources préchargées"
      Enum.each(paths, &assert(sp_md =~ &1))
    end

    test "stable_sha256 is identical across 100 invocations on same input", %{
      sp_role_root: sp_root,
      modop_root: mop_root
    } do
      write_sp_role(sp_root, "engineer-role.md", "# Role base")
      write_modop_sp(mop_root, "fire-mode", "# fire-mode")

      shas =
        for _ <- 1..100 do
          {:ok, %{stable_sha256: sha}} =
            Fleet.SPBuilder.compose(valid_cap_profile(), ["fire-mode"], pod_id: "p-1")

          sha
        end

      assert shas |> Enum.uniq() |> length() == 1
    end

    test "stable_sha256 is invariant to pod_id and spawned_at changes", %{sp_role_root: sp_root} do
      write_sp_role(sp_root, "engineer-role.md", "# Role")

      profile = valid_cap_profile()

      {:ok, %{stable_sha256: sha_a}} =
        Fleet.SPBuilder.compose(profile, [],
          pod_id: "p-1",
          spawned_at: ~U[2026-05-09 10:00:00Z]
        )

      {:ok, %{stable_sha256: sha_b}} =
        Fleet.SPBuilder.compose(profile, [],
          pod_id: "p-99-other",
          spawned_at: ~U[2026-05-09 23:59:59Z]
        )

      assert sha_a == sha_b
    end

    test "stable_sha256 differs when modop order is changed (precedence)", %{
      sp_role_root: sp_root,
      modop_root: mop_root
    } do
      write_sp_role(sp_root, "engineer-role.md", "# Role")
      write_modop_sp(mop_root, "m1", "# m1")
      write_modop_sp(mop_root, "m2", "# m2")

      {:ok, %{stable_sha256: a}} = Fleet.SPBuilder.compose(valid_cap_profile(), ["m1", "m2"])
      {:ok, %{stable_sha256: b}} = Fleet.SPBuilder.compose(valid_cap_profile(), ["m2", "m1"])

      assert a != b
    end

    test "stable_sha256 differs when preloaded_paths change", %{sp_role_root: sp_root} do
      write_sp_role(sp_root, "engineer-role.md", "# Role")

      {:ok, %{stable_sha256: sha_a}} =
        Fleet.SPBuilder.compose(valid_cap_profile(), [], preloaded_paths: ["/tmp/a.md"])

      {:ok, %{stable_sha256: sha_b}} =
        Fleet.SPBuilder.compose(valid_cap_profile(), [], preloaded_paths: ["/tmp/b.md"])

      assert sha_a != sha_b
    end
  end

  # ============================================================
  # compose_claude_md/3
  # ============================================================

  describe "compose_claude_md/3" do
    test "renders conventions without repo CLAUDE.md path" do
      assert {:ok, claude_md} = Fleet.SPBuilder.compose_claude_md(valid_cap_profile(), nil)

      assert claude_md =~ "Identité"
      assert claude_md =~ "engineer"
      assert claude_md =~ "bwrap"
      refute claude_md =~ "Repo conventions"
    end

    # R12: compose_claude_md reads lifetime_scope under spec.invocation (v2.5).
    # Reading spec.lifetime_scope instead would always render "unknown".
    test "surfaces lifetime_scope from spec.invocation (not 'unknown')" do
      profile =
        valid_cap_profile(%{"invocation" => %{"lifetime_scope" => "forever"}})

      assert {:ok, claude_md} = Fleet.SPBuilder.compose_claude_md(profile, nil)
      assert claude_md =~ "forever"
      refute claude_md =~ "scope : unknown"
    end

    test "extracts named sections from repo CLAUDE.md when provided", %{tmp_dir: tmp_dir} do
      repo_md = Path.join(tmp_dir, "CLAUDE.md")

      File.write!(repo_md, """
      # Project

      Some intro.

      ## Stack

      Elixir + OTP.

      ## Random

      Should be ignored.

      ## Build

      mix release.
      """)

      assert {:ok, claude_md} = Fleet.SPBuilder.compose_claude_md(valid_cap_profile(), repo_md)
      assert claude_md =~ "Stack"
      assert claude_md =~ "Elixir + OTP"
      assert claude_md =~ "Build"
      assert claude_md =~ "mix release"
      refute claude_md =~ "Random"
    end

    test "returns :repo_claude_md_unreadable when path absent" do
      assert {:error, {:repo_claude_md_unreadable, _path, _reason}} =
               Fleet.SPBuilder.compose_claude_md(valid_cap_profile(), "/tmp/__no_such_file")
    end
  end

  # ============================================================
  # filter_skills/2
  # ============================================================

  describe "filter_skills/2" do
    test "returns paths matching whitelist that exist on FS", %{tmp_dir: tmp_dir} do
      skills_root = Path.join(tmp_dir, "skills")
      File.mkdir_p!(Path.join(skills_root, "memory-query"))
      File.mkdir_p!(Path.join(skills_root, "loop"))
      File.mkdir_p!(Path.join(skills_root, "extra-not-listed"))

      assert {:ok, paths} = Fleet.SPBuilder.filter_skills(valid_cap_profile(), skills_root)
      assert length(paths) == 2
      assert Enum.any?(paths, &String.ends_with?(&1, "memory-query"))
      assert Enum.any?(paths, &String.ends_with?(&1, "loop"))
      refute Enum.any?(paths, &String.ends_with?(&1, "extra-not-listed"))
    end

    # R11: a plain whitelisted skill absent from the FS = fail-loud (no silent
    # filtering). Here "loop" is missing (only "memory-query" exists).
    test "fail-loud {:skills_missing} when a whitelisted skill is absent from the FS",
         %{tmp_dir: tmp_dir} do
      skills_root = Path.join(tmp_dir, "skills")
      File.mkdir_p!(Path.join(skills_root, "memory-query"))

      assert {:error, {:skills_missing, ["loop"]}} =
               Fleet.SPBuilder.filter_skills(valid_cap_profile(), skills_root)
    end

    # R11: QUALIFIED `plugin:skill` skills are delivered via LCARS_SKILLS_PLUGINS,
    # not as mounted paths → NEVER flagged absent (even if the path does not exist).
    test "plugin:skill skills are not flagged absent", %{tmp_dir: tmp_dir} do
      skills_root = Path.join(tmp_dir, "skills")
      File.mkdir_p!(Path.join(skills_root, "memory-query"))
      File.mkdir_p!(Path.join(skills_root, "loop"))

      profile =
        valid_cap_profile(%{
          "knowledge" => %{"skills" => ["memory-query", "loop", "elixir:otp-thinking"]}
        })

      assert {:ok, paths} = Fleet.SPBuilder.filter_skills(profile, skills_root)
      assert length(paths) == 2
      refute Enum.any?(paths, &String.contains?(&1, "otp-thinking"))
    end

    test "returns :skills_root_missing when path absent" do
      assert {:error, :skills_root_missing} =
               Fleet.SPBuilder.filter_skills(valid_cap_profile(), "/tmp/__no_such_dir")
    end
  end

  # ============================================================
  # Property-based — sha256 determinism
  # ============================================================

  defp non_empty_string_gen do
    string(:alphanumeric, min_length: 1, max_length: 24)
  end

  property "stable_sha256 is invariant under arbitrary pod_id/spawned_at", %{
    sp_role_root: sp_root
  } do
    write_sp_role(sp_root, "engineer-role.md", "# Role")
    profile = valid_cap_profile()
    base = ~U[2026-01-01 00:00:00Z]

    {:ok, %{stable_sha256: baseline}} = Fleet.SPBuilder.compose(profile, [], pod_id: "p-baseline")

    check all(
            pod_id <- non_empty_string_gen(),
            secs <- integer(0..86_400)
          ) do
      spawned = DateTime.add(base, secs, :second)

      {:ok, %{stable_sha256: candidate}} =
        Fleet.SPBuilder.compose(profile, [], pod_id: pod_id, spawned_at: spawned)

      assert baseline == candidate
    end
  end

  property "stable_sha256 stable across two consecutive identical calls", %{
    sp_role_root: sp_root,
    modop_root: mop_root
  } do
    write_sp_role(sp_root, "engineer-role.md", "# Role")
    write_modop_sp(mop_root, "m1", "# m1")
    write_modop_sp(mop_root, "m2", "# m2")

    check all(modops <- list_of(member_of(["m1", "m2"]), max_length: 4)) do
      {:ok, %{stable_sha256: a}} = Fleet.SPBuilder.compose(valid_cap_profile(), modops)
      {:ok, %{stable_sha256: b}} = Fleet.SPBuilder.compose(valid_cap_profile(), modops)
      assert a == b
    end
  end
end
