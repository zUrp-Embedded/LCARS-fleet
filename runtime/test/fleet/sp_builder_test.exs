defmodule Fleet.SPBuilderTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    modop_root = Path.join(tmp_dir, "modop")
    File.mkdir_p!(modop_root)

    prev_mod = Application.get_env(:lcars_fleet, :sp_builder_modop_root)
    Application.put_env(:lcars_fleet, :sp_builder_modop_root, modop_root)
    on_exit(fn -> Application.put_env(:lcars_fleet, :sp_builder_modop_root, prev_mod) end)

    {:ok, modop_root: modop_root}
  end

  defp valid_cap_profile(extra_spec \\ %{}) do
    spec =
      Map.merge(
        %{
          "scope" => %{
            "disallowedTools" => ["web_search", "tool_search_internal"],
            "git_ops_denied" => ["push"]
          },
          "knowledge" => %{"skills" => ["memory-query", "loop"]},
          "invocation" => %{"lifetime_scope" => "one-shot"},
          "injects" => %{},
          "budget" => %{"maxUsd" => 1.0, "maxDurationSec" => 600},
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

  defp write_modop_sp(modop_root, name, content) do
    dir = Path.join(modop_root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "sp.md"), content)
  end

  describe "compose/3" do
    test "composes SP from cap-profile with no modop bundles" do
      assert {:ok,
              %{
                sp_md: sp_md,
                stable_sha256: sha,
                metadata: %{modop_bundles_used: []}
              }} = Fleet.SPBuilder.compose(valid_cap_profile(), [], pod_id: "p-1", job_id: "j-1")

      assert sp_md =~ "p-1"
      assert is_binary(sha) and byte_size(sha) == 64
    end

    test "composes SP with modop bundles in declared order", %{modop_root: mop_root} do
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

    test "returns :modop_bundle_missing when a modop sp.md is absent" do
      assert {:error, {:modop_bundle_missing, "ghost"}} =
               Fleet.SPBuilder.compose(valid_cap_profile(), ["ghost"])
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

    test "R1-02/03: modop bundle with traversal (`../`) → {:error, {:modop_bundle_unsafe, _}} (confined_join)" do
      profile = valid_cap_profile()

      assert {:error, {:modop_bundle_unsafe, {"../evil", _}}} =
               Fleet.SPBuilder.compose(profile, ["../evil"])
    end

    test "R1-29: a non-slug skill name (traversal) → {:error, {:skills_unsafe, _}}", %{
      modop_root: root
    } do
      # `root` exists (dir) → we get past the File.dir? guard; "../../etc" is rejected BEFORE File.exists?.
      profile = valid_cap_profile(%{"knowledge" => %{"skills" => ["../../etc", "loop"]}})

      assert {:error, {:skills_unsafe, ["../../etc"]}} =
               Fleet.SPBuilder.filter_skills(profile, root)
    end

    test "modop_root has a DEFAULT (fleet_cap_profile/modop-bundles): modop without explicit config → composed (F-C146/PORT)" do
      # Direct compose with the shipped default root; this does not prove step-selected
      # optional modops survive dispatch into Pod. CapProfile documents that separate path.
      Application.delete_env(:lcars_fleet, :sp_builder_modop_root)
      profile = valid_cap_profile(%{"systemPrompt" => nil})

      assert {:ok, %{sp_md: sp_md, metadata: %{modop_bundles_used: ["fire-mode"]}}} =
               Fleet.SPBuilder.compose(profile, ["fire-mode"])

      assert sp_md =~ "fire-mode"
    end

    @tag :tmp_dir
    test "subagent_template (F-C147/PORT): the SP fragment is injected; missing file → fail-loud",
         %{tmp_dir: tmp} do
      # Own the fixture: template resolution must remain tested when shipped templates retire.
      root = Path.join(tmp, "subagent-templates")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "subagent-fixture-lentille.md"), "# fixture lentille\ncorps\n")

      prev = Application.get_env(:lcars_fleet, :sp_builder_subagent_template_root)
      Application.put_env(:lcars_fleet, :sp_builder_subagent_template_root, root)

      on_exit(fn ->
        Application.put_env(:lcars_fleet, :sp_builder_subagent_template_root, prev)
      end)

      profile =
        valid_cap_profile(%{
          "systemPrompt" => nil,
          "invocation" => %{
            "lifetime_scope" => "one-shot",
            "subagent_template" => "fixture-lentille"
          }
        })

      assert {:ok, %{sp_md: sp_md}} = Fleet.SPBuilder.compose(profile, [])
      assert sp_md =~ "subagent-template:fixture-lentille"
      assert sp_md =~ "fixture lentille"

      bad =
        valid_cap_profile(%{
          "systemPrompt" => nil,
          "invocation" => %{"subagent_template" => "inexistant-xyz"}
        })

      assert {:error, {:subagent_template_missing, "inexistant-xyz"}} =
               Fleet.SPBuilder.compose(bad, [])
    end

    test "preloaded_paths section is included when given" do
      paths = ["/tmp/preloaded-1.md", "/tmp/preloaded-2.md"]

      assert {:ok, %{sp_md: sp_md}} =
               Fleet.SPBuilder.compose(valid_cap_profile(), [], preloaded_paths: paths)

      assert sp_md =~ "Ressources préchargées"
      Enum.each(paths, &assert(sp_md =~ &1))
    end

    test "stable_sha256 is identical across 100 invocations on same input", %{
      modop_root: mop_root
    } do
      write_modop_sp(mop_root, "fire-mode", "# fire-mode")

      shas =
        for _ <- 1..100 do
          {:ok, %{stable_sha256: sha}} =
            Fleet.SPBuilder.compose(valid_cap_profile(), ["fire-mode"], pod_id: "p-1")

          sha
        end

      assert shas |> Enum.uniq() |> length() == 1
    end

    test "stable_sha256 is invariant to pod_id and spawned_at changes" do
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
      modop_root: mop_root
    } do
      write_modop_sp(mop_root, "m1", "# m1")
      write_modop_sp(mop_root, "m2", "# m2")

      {:ok, %{stable_sha256: a}} = Fleet.SPBuilder.compose(valid_cap_profile(), ["m1", "m2"])
      {:ok, %{stable_sha256: b}} = Fleet.SPBuilder.compose(valid_cap_profile(), ["m2", "m1"])

      assert a != b
    end

    test "stable_sha256 differs when preloaded_paths change" do
      {:ok, %{stable_sha256: sha_a}} =
        Fleet.SPBuilder.compose(valid_cap_profile(), [], preloaded_paths: ["/tmp/a.md"])

      {:ok, %{stable_sha256: sha_b}} =
        Fleet.SPBuilder.compose(valid_cap_profile(), [], preloaded_paths: ["/tmp/b.md"])

      assert sha_a != sha_b
    end
  end

  describe "compose_claude_md/3" do
    test "renders conventions without repo CLAUDE.md path" do
      assert {:ok, claude_md} = Fleet.SPBuilder.compose_claude_md(valid_cap_profile(), nil)

      assert claude_md =~ "Identité"
      assert claude_md =~ "engineer"
      assert claude_md =~ "bwrap"
      refute claude_md =~ "Repo conventions"
    end

    # R12: compose_claude_md reads lifetime_scope under spec.invocation.
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

    test "the pod is told to prove its deliverable, and what to do when the repo does not say how" do
      # Keep the proof instruction in producer-output, out of universal evidence and the
      # composed CLAUDE.md. This protects the split from judges' instructions and avoids
      # restoring the overwrite/skip-worktree scheme that hid legitimate project-doc edits.
      # These are artifact-content checks via Catalogue.find, not full role composition.
      evidence =
        Fleet.Catalogue.find(
          Fleet.Catalogue.root(),
          Fleet.Catalogue.rel(:sp_blocks),
          "core/evidence.md"
        )
        |> File.read!()

      producer_output =
        Fleet.Catalogue.find(
          Fleet.Catalogue.root(),
          Fleet.Catalogue.rel(:sp_blocks),
          "core/producer-output.md"
        )
        |> File.read!()

      assert evidence =~ "## Preuve avant action"
      # Judges should not inherit an instruction to replay the runner's suite.
      refute evidence =~ "Prouver ce que tu livres"

      assert producer_output =~ "Prouver ce que tu livres"

      # WHERE to look — the exact heading the extraction carries over, not a vague "the repo doc".
      assert producer_output =~ "## Test"
      # And the clause that makes a missing runner visible rather than silently assumed.
      assert producer_output =~ "mensonge opérationnel"

      assert {:ok, claude_md} = Fleet.SPBuilder.compose_claude_md(valid_cap_profile(), nil)
      refute claude_md =~ "Prouver ce que tu livres"

      # Keep internal permission configuration out of the frequently reread project doc.
      refute claude_md =~ "Contraintes pod"
      refute claude_md =~ "disallowedTools"
      refute claude_md =~ "git_ops_denied"
    end

    # Pin the machine-readable findings vocabulary in the judge artifact.
    test "the judge is told the machine key and its shape (details.findings)" do
      judge_verdict =
        Fleet.Catalogue.find(
          Fleet.Catalogue.root(),
          Fleet.Catalogue.rel(:sp_blocks),
          "core/judge-verdict.md"
        )
        |> File.read!()

      assert judge_verdict =~ "details.findings"
      # The TWO reconciled production vocabularies, named — never a third (spec-reviewer's
      # severity/category/verdict triples + the moon-shot 0-10 mechanical score).
      assert judge_verdict =~ "critical|important|minor"
      assert judge_verdict =~ "missing|extra|divergent"
      assert judge_verdict =~ "proven|partial|fail"
      assert judge_verdict =~ "0-10"
      # And the failure direction the rail implements, told to the judge in its own words.
      assert judge_verdict =~ "ne casse PAS ton verdict"
    end

    test "returns :repo_claude_md_unreadable when path absent" do
      assert {:error, {:repo_claude_md_unreadable, _path, _reason}} =
               Fleet.SPBuilder.compose_claude_md(valid_cap_profile(), "/tmp/__no_such_file")
    end
  end

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

    test "racine metier absente mais systeme presente → les skills manquent, pas la racine" do
      # A system root exists: diagnose missing skill names, not absent deployment roots.
      assert {:error, {:skills_missing, missing}} =
               Fleet.SPBuilder.filter_skills(valid_cap_profile(), "/tmp/__no_such_dir")

      assert missing != []
    end

    @tag :tmp_dir
    test "AUCUNE des deux racines → :skills_root_missing (le vrai deploiement casse)", %{
      tmp_dir: tmp
    } do
      Fleet.Test.CatalogueIsolation.isolate!(tmp, system: Path.join(tmp, "__absent"))

      assert {:error, :skills_root_missing} =
               Fleet.SPBuilder.filter_skills(valid_cap_profile(), "/tmp/__no_such_dir")
    end
  end

  defp non_empty_string_gen do
    string(:alphanumeric, min_length: 1, max_length: 24)
  end

  property "stable_sha256 is invariant under arbitrary pod_id/spawned_at" do
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
    modop_root: mop_root
  } do
    write_modop_sp(mop_root, "m1", "# m1")
    write_modop_sp(mop_root, "m2", "# m2")

    check all(modops <- list_of(member_of(["m1", "m2"]), max_length: 4)) do
      {:ok, %{stable_sha256: a}} = Fleet.SPBuilder.compose(valid_cap_profile(), modops)
      {:ok, %{stable_sha256: b}} = Fleet.SPBuilder.compose(valid_cap_profile(), modops)
      assert a == b
    end
  end
end
