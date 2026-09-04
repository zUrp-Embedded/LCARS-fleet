defmodule Fleet.SPBuilderTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  # `doctest Fleet.SPBuilder` RETIRE le 2026-08-06 : le module n'a JAMAIS porte d'exemple `iex>`
  # (`git log -S` sur ce fichier ne rend rien). La ligne declarait une couverture qui n'a jamais
  # existe — zero cas execute, et un lecteur qui voit `doctest` croit le contraire. Retirer une
  # ligne qui n'execute rien ne retire aucun test : le compte de la suite est identique avant et
  # apres. Trouve par le check `tests.doctest_declarations_have_examples`, ecrit le jour meme.

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    modop_root = Path.join(tmp_dir, "modop")
    File.mkdir_p!(modop_root)

    prev_mod = Application.get_env(:lcars_fleet, :sp_builder_modop_root)
    Application.put_env(:lcars_fleet, :sp_builder_modop_root, modop_root)
    on_exit(fn -> Application.put_env(:lcars_fleet, :sp_builder_modop_root, prev_mod) end)

    {:ok, modop_root: modop_root}
  end

  # ============================================================
  # Fixtures
  # ============================================================

  defp valid_cap_profile(extra_spec \\ %{}) do
    spec =
      Map.merge(
        %{
          "scope" => %{
            "disallowedTools" => ["web_search", "tool_search_internal"],
            "git_ops_denied" => ["push"]
          },
          "knowledge" => %{"skills" => ["memory-query", "loop"]},
          # R12: lifetime_scope nested under invocation (cap-profile schema).
          "invocation" => %{"lifetime_scope" => "one-shot"},
          "injects" => %{},
          "budget" => %{"maxUsd" => 1.0, "maxDurationSec" => 600},
          # modop_set = MAP (schema: default/optional/incompatible).
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

  # ============================================================
  # compose/3
  # ============================================================

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
      # EXERCISES the runtime DEFAULT: remove the override → modop_root unconfigured → default
      # app_dir(:lcars_fleet, "priv/catalogue/cap_profile/modop-bundles") (where the bundles live).
      # `fire-mode` exists there → composed. No :modop_root_unconfigured: the PORT wired the
      # default.
      #
      # SCOPE of this proof, since the default is easy to over-read: it shows that `SPBuilder.compose`
      # RESOLVES its bundle root without an explicit config. It does NOT show that a step's modops
      # reach a pod — this calls `compose` DIRECTLY with a list, while the spawn path is
      # `CapProfile.resolve/3` → `Pod`, which re-derives the list from `default_modops/1` and drops
      # any step-selected optional modop on the way (see the KNOWN GAP note on the B-01 guard in
      # `Fleet.CapProfile`). "The root resolves" and "the overlay reaches the pod" are two claims;
      # only the first is tested here.
      Application.delete_env(:lcars_fleet, :sp_builder_modop_root)
      profile = valid_cap_profile(%{"systemPrompt" => nil})

      assert {:ok, %{sp_md: sp_md, metadata: %{modop_bundles_used: ["fire-mode"]}}} =
               Fleet.SPBuilder.compose(profile, ["fire-mode"])

      # The fire-mode modop's SP fragment is indeed INJECTED into the system-prompt.
      assert sp_md =~ "fire-mode"
    end

    @tag :tmp_dir
    test "subagent_template (F-C147/PORT): the SP fragment is injected; missing file → fail-loud",
         %{tmp_dir: tmp} do
      # ⚠ CE TEST EMPRUNTAIT SON ARTEFACT AU CANON, ET LE CANON A CHANGÉ. Il composait
      # `code-quality-reviewer` en comptant sur `subagent-code-quality-reviewer.md` livré par le
      # catalogue — donc sur une COÏNCIDENCE : que ce fichier existe encore. La sortie de
      # superpowers (⚖ user 2026-08-19) l'a supprimé avec ses deux frères, et le test est tombé
      # alors que le MÉCANISME qu'il existe pour prouver n'avait pas bougé d'une ligne.
      #
      # Il fabrique donc son propre template, comme le fait déjà `catalogue_verify_test` depuis le
      # même jour : ce qu'on veut prouver, c'est qu'un fragment DÉCLARÉ est injecté et qu'un
      # fragment déclaré-mais-absent échoue fort — deux propriétés du composeur, qui ne doivent
      # rien devoir au contenu du catalogue.
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

      # Declared but file absent → fail-loud (the pod does not launch on a half-composed SP).
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

    # D1 — the pod's own CLAUDE.md said what it was FORBIDDEN and never how to prove a deliverable.
    # A producer with no test command has two ways out and one of them is a lie; this block closes
    # the second by naming it, so the absence gets REPORTED instead of papered over with "tests
    # green". Rule P2(b): the obligation, not the observation.
    test "the pod is told to prove its deliverable, and what to do when the repo does not say how" do
      # ⚠ CETTE DOCTRINE A DEMENAGE, ET LE DEMENAGEMENT EST LE SUJET DU TEST. Elle vivait dans le
      # `CLAUDE.md` compose — un fichier ECRIT PAR-DESSUS celui du depot, qu'il fallait ensuite
      # masquer (`skip-worktree`) pour qu'il ne parte pas dans le livrable. Ce masquage rendait le
      # `CLAUDE.md` du projet INLIVRABLE : un producteur qui l'editait voyait `git status` propre.
      # La doctrine est donc partie dans les blocs SP, qui arrivent par `--system-prompt-file`
      # (remplacant et fiable), et le fichier du depot est redevenu celui du depot.
      #
      # Le test tient les DEUX bouts : la doctrine existe toujours pour l'agent, et elle n'est plus
      # dans le fichier qui doit rester livrable. Sans la seconde assertion, la reintroduire dans le
      # template rouvrirait le piege sans qu'aucun test ne bronche.
      # Le MEME resolveur que le compositeur (`Blocks`), jamais un chemin rebati : les blocs vivent
      # dans le catalogue systeme, la carte dans le catalogue metier, et un chemin en dur ici
      # mesurerait un fichier que la fleet ne lit pas.
      # (Lot B, 2026-08-18) SECOND déménagement, même sujet : l'ordre de preuve a quitté
      # `core/evidence.md` (composé chez les DIX rôles — un juge qui obéissait rejouait la suite
      # que le runner venait d'exécuter) pour `core/producer-output.md` (producteurs seuls). Le
      # test suit, et tient désormais TROIS bouts : la doctrine existe pour le producteur, le
      # socle universel reste chez tous, et l'ordre n'est PLUS chez les juges.
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

      # The universal floor stays with everyone…
      assert evidence =~ "## Preuve avant action"
      # …and the proof ORDER left it: a judge must not be told to replay the runner's suite.
      refute evidence =~ "Prouver ce que tu livres"

      assert producer_output =~ "Prouver ce que tu livres"

      # WHERE to look — the exact heading the extraction carries over, not a vague "the repo doc".
      assert producer_output =~ "## Test"
      # And the clause that makes a missing runner visible rather than silently assumed.
      assert producer_output =~ "mensonge opérationnel"

      assert {:ok, claude_md} = Fleet.SPBuilder.compose_claude_md(valid_cap_profile(), nil)
      refute claude_md =~ "Prouver ce que tu livres"

      # The containment doctrine it replaced: a constat that named the interdictions to the very
      # agent they confine, and told it nothing it could act on. N8/A8 — same family as the launch
      # trace that handed a confined agent the table of its own confinement.
      #
      # `git_ops_denied` went with it, and the reason is MEASURED, not aesthetic: a denied Bash
      # pattern announces itself precisely at the moment it bites — "Permission to use Bash with
      # command `git push origin main` has been denied" — and the agent attributes it to the
      # permission layer, not to git, and does not retry. The obligation that replaces it is not
      # here but where behaviour is shaped: the role SP already says "tu commites en LOCAL et le
      # SYSTÈME pousse — tu ne push JAMAIS". Naming the wall a second time, in the file the agent
      # re-reads most, bought nothing and cost the map of its own cage.
      refute claude_md =~ "Contraintes pod"
      refute claude_md =~ "disallowedTools"
      refute claude_md =~ "git_ops_denied"
    end

    # C1 2026-08-18 — the machine key is a CONSIGNE, not a guessed convention: the block that
    # defines a judge's output NAMES `details.findings` and its shape. Same resolver as the
    # composer (`Catalogue.find`), same reason as the D1 test above: a hardcoded path here would
    # measure a file the fleet does not read.
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

    # Deux absences distinctes depuis le decoupage systeme/metier, et les confondre serait un
    # mensonge dans les deux sens.
    test "racine metier absente mais systeme presente → les skills manquent, pas la racine" do
      # Le deploiement A un arbre de skills (celui du systeme) : repondre `:skills_root_missing`
      # dirait qu'il n'y en a aucun, et enverrait l'operateur chercher un probleme de deploiement
      # la ou il a simplement nomme des skills qui n'existent pas.
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

  # ============================================================
  # Property-based — sha256 determinism
  # ============================================================

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
