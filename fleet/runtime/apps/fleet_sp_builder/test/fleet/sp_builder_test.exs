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
          "lifetime_scope" => "one-shot",
          "systemPrompt" => "engineer-role.md",
          "scope" => %{
            "disallowedTools" => ["web_search", "tool_search_internal"],
            "git_ops_denied" => ["push"]
          },
          "knowledge" => %{"skills" => ["memory-query", "loop"]},
          "invocation" => %{},
          "injects" => %{},
          "budget" => %{"maxUsd" => 1.0, "maxDurationSec" => 600},
          "modop_set" => []
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

    test "silently skips whitelist entries absent from FS", %{tmp_dir: tmp_dir} do
      skills_root = Path.join(tmp_dir, "skills")
      File.mkdir_p!(Path.join(skills_root, "memory-query"))

      assert {:ok, paths} = Fleet.SPBuilder.filter_skills(valid_cap_profile(), skills_root)
      assert length(paths) == 1
    end

    test "returns :skills_root_missing when path absent" do
      assert {:error, :skills_root_missing} =
               Fleet.SPBuilder.filter_skills(valid_cap_profile(), "/tmp/__no_such_dir")
    end
  end

  # ============================================================
  # Property-based — déterminisme sha256
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
