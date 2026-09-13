defmodule Fleet.Project.OnboardTest do
  @moduledoc """
  Repository-create classification, teardown identity checks and reconciliation/admission guards.
  Already-exists responses must not enter fresh scaffolding. Convergence is a separate path.
  Source-reading tests below check code shape; they do not replace behavioral coverage.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fleet.Project.Onboard, as: ProjectOnboard

  describe "classify_create_repo/3 (F-C084 — pre-existing repo is not an onboard target)" do
    test "genuine CREATE ({:ok, full_name}) → {:ok, full_name} (onboard owns the fresh repo)" do
      assert {:ok, "fleet/neuf"} =
               ProjectOnboard.Repo.classify_create_repo({:ok, "fleet/neuf"}, "fleet", "neuf")
    end

    test "repo ALREADY existing (409 → {:ok, :already_exists}) → {:error, {:repo_already_exists, _}} (FAIL-LOUD)" do
      # Already-exists must be a refusal here, or fresh scaffolding could overwrite main.
      assert {:error, {:repo_already_exists, "fleet/deja"}} =
               ProjectOnboard.Repo.classify_create_repo({:ok, :already_exists}, "fleet", "deja")
    end

    test "forge error propagated as-is (no interpretation)" do
      assert {:error, {:http, 500, "boom"}} =
               ProjectOnboard.Repo.classify_create_repo(
                 {:error, {:http, 500, "boom"}},
                 "fleet",
                 "x"
               )
    end
  end

  describe "delete_project/2 (general project teardown — FAIL-CLOSED, CI-07)" do
    defmodule OkRepo do
      def default_branch(_repo, _opts), do: {:ok, "main"}

      def delete_repo(repo, _opts) do
        send(self(), {:delete_repo, repo})
        :ok
      end
    end

    defmodule AbsentRepo do
      def default_branch(_repo, _opts), do: {:error, {:http, 404, "no repo"}}

      def delete_repo(repo, _opts) do
        send(self(), {:delete_repo, repo})
        :ok
      end
    end

    defmodule OutageRepo do
      def default_branch(_repo, _opts), do: {:error, {:http, 500, "boom"}}

      def delete_repo(repo, _opts) do
        send(self(), {:delete_repo, repo})
        :ok
      end
    end

    defmodule OkSpawner do
      def kill_pod(pod_id) do
        send(self(), {:kill_pod, pod_id})
        :ok
      end

      def kill_project_pods(repo) do
        send(self(), {:swept, repo})
        {:ok, %{killed: 2, pod_ids: ["fleet-demo-issue-7-engineer", "fleet-demo-pr-3-reviewer"]}}
      end
    end

    defmodule NoArchSpawner do
      def kill_pod(_pod_id), do: {:error, :not_found}
      def kill_project_pods(_repo), do: {:ok, %{killed: 0, pod_ids: []}}
    end

    # Origins name owner/repo so deletion can distinguish same-basename directories.
    defp init_repo_with_origin(dir, origin_url) do
      File.mkdir_p!(dir)
      {_out, 0} = System.cmd("git", ["init", "-q", dir])
      {_out, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", origin_url])
      :ok
    end

    setup %{tmp_dir: tmp} do
      proj_root = Path.join(tmp, "projects")
      ops_root = Path.join(tmp, "work")
      workshop_root = Path.join(tmp, "doc")
      proj_dir = Path.join(proj_root, "demo")
      work_dir = Path.join(ops_root, "demo")
      doc_dir = Path.join(workshop_root, "demo")

      init_repo_with_origin(proj_dir, "https://forge.test/fleet/demo.git")
      init_repo_with_origin(work_dir, "https://forge.test/fleet/demo.git")
      init_repo_with_origin(doc_dir, "https://forge.test/fleet/demo.git")

      {:ok,
       proj_root: proj_root,
       ops_root: ops_root,
       workshop_root: workshop_root,
       proj_dir: proj_dir,
       work_dir: work_dir,
       doc_dir: doc_dir}
    end

    defp del(ctx, extra) do
      ProjectOnboard.delete_project(
        "fleet/demo",
        Keyword.merge(
          [
            code_root: ctx.proj_root,
            ops_root: ctx.ops_root,
            workshop_root: ctx.workshop_root,
            spawner: OkSpawner
          ],
          extra
        )
      )
    end

    @tag :tmp_dir
    test "the project's WORKERS are swept BEFORE the faces go, and the count is reported", ctx do
      # Worker cleanup must be requested and its count returned. These assertions do not time it
      # relative to directory removal or exercise real running workers.
      assert {:ok, result} = del(ctx, force: true, forge_repo: OkRepo)

      assert_received {:swept, "fleet/demo"}
      assert result.workers_killed == 2
    end

    @tag :tmp_dir
    test "WITHOUT force → {:error, force_required}, touches NOTHING (fail-closed, no valueless heuristic)",
         ctx do
      # Zero fleet issues does not imply disposable content. Without force, refuse deletion.
      assert {:error, {:force_required, "fleet/demo"}} = del(ctx, forge_repo: OkRepo)

      refute_received {:delete_repo, _}
      refute_received {:kill_pod, _}
      assert File.exists?(ctx.proj_dir)
      assert File.exists?(ctx.work_dir)
    end

    @tag :tmp_dir
    test "force: true → forge deleted + arch stopped + dirs removed", ctx do
      assert {:ok, %{repo: "fleet/demo", forge: :deleted, architect: :stopped}} =
               del(ctx, force: true, forge_repo: OkRepo)

      assert_received {:delete_repo, "fleet/demo"}
      assert_received {:kill_pod, "architect-demo"}
      refute File.exists?(ctx.proj_dir)
      refute File.exists?(ctx.work_dir)
    end

    @tag :tmp_dir
    test "force + absent forge repo (404) → forge: :absent, dirs removed, no delete call", ctx do
      assert {:ok, %{forge: :absent, architect: :none}} =
               del(ctx, force: true, forge_repo: AbsentRepo, spawner: NoArchSpawner)

      refute_received {:delete_repo, _}
      refute File.exists?(ctx.proj_dir)
    end

    @tag :tmp_dir
    test "force + forge outage (non-404) → {:error, forge_check_failed}, NOTHING nuked", ctx do
      assert {:error, {:forge_check_failed, {:http, 500, "boom"}}} =
               del(ctx, force: true, forge_repo: OutageRepo)

      refute_received {:delete_repo, _}
      assert File.exists?(ctx.proj_dir)
    end

    @tag :tmp_dir
    test "force + WRONG owner (homonym) + forge 404 → local dirs KEPT, architect untouched",
         ctx do
      # A forge 404 for other/demo must not authorize removing local fleet/demo.
      assert {:ok,
              %{
                repo: "other/demo",
                forge: :absent,
                architect: :skipped_identity,
                local: %{project: :kept_identity_unproven, ops: :kept_identity_unproven}
              }} =
               ProjectOnboard.delete_project(
                 "other/demo",
                 code_root: ctx.proj_root,
                 ops_root: ctx.ops_root,
                 workshop_root: ctx.workshop_root,
                 force: true,
                 forge_repo: AbsentRepo,
                 spawner: OkSpawner
               )

      refute_received {:kill_pod, _}
      assert File.exists?(ctx.proj_dir)
      assert File.exists?(ctx.work_dir)
    end

    @tag :tmp_dir
    test "force + right owner but local origin is a DIFFERENT project → that dir KEPT (basename collision)",
         ctx do
      File.rm_rf!(ctx.proj_dir)
      init_repo_with_origin(ctx.proj_dir, "https://forge.test/someone-else/demo.git")

      assert {:ok, %{forge: :deleted, local: %{project: :kept_identity_unproven, ops: :removed}}} =
               del(ctx, force: true, forge_repo: OkRepo)

      assert File.exists?(ctx.proj_dir)
      refute File.exists?(ctx.work_dir)
    end

    @tag :tmp_dir
    test "force + NO origin + provably empty → removed as onboard debris (the wedge is gone)",
         ctx do
      # Empty initialized repos without origins can be residue from an interrupted onboard.
      File.rm_rf!(ctx.work_dir)
      File.mkdir_p!(ctx.work_dir)
      {_out, 0} = System.cmd("git", ["init", "-q", "-b", "ops", ctx.work_dir])

      assert {:ok, %{local: %{project: :removed, ops: :removed}}} =
               del(ctx, force: true, forge_repo: OkRepo)

      refute File.exists?(ctx.work_dir)
    end

    @tag :tmp_dir
    test "force + NO origin but COMMITS present → KEPT (a local-only repo is never ours to erase)",
         ctx do
      # No origin alone is insufficient: committed local work must survive.
      File.rm_rf!(ctx.work_dir)
      File.mkdir_p!(ctx.work_dir)
      {_out, 0} = System.cmd("git", ["init", "-q", "-b", "ops", ctx.work_dir])
      File.write!(Path.join(ctx.work_dir, "notes.md"), "someone's local-only work")
      {_out, 0} = System.cmd("git", ["-C", ctx.work_dir, "add", "-A"])

      {_out, 0} =
        System.cmd("git", [
          "-C",
          ctx.work_dir,
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@t",
          "commit",
          "-qm",
          "keep me"
        ])

      assert {:ok, %{local: %{ops: :kept_identity_unproven}}} =
               del(ctx, force: true, forge_repo: OkRepo)

      assert File.exists?(ctx.work_dir)
      assert File.exists?(Path.join(ctx.work_dir, "notes.md"))
    end

    @tag :tmp_dir
    test "force + NO origin, no commit, but UNCOMMITTED content → KEPT (both halves are load-bearing)",
         ctx do
      # No commits does not imply empty: uncommitted scaffold files must survive.
      File.rm_rf!(ctx.work_dir)
      File.mkdir_p!(ctx.work_dir)
      {_out, 0} = System.cmd("git", ["init", "-q", "-b", "ops", ctx.work_dir])
      File.write!(Path.join(ctx.work_dir, "draft.md"), "uncommitted, still someone's")

      assert {:ok, %{local: %{ops: :kept_identity_unproven}}} =
               del(ctx, force: true, forge_repo: OkRepo)

      assert File.exists?(Path.join(ctx.work_dir, "draft.md"))
    end

    @tag :tmp_dir
    test "force + NO origin, EMPTY worktree but history present → KEPT (the commit check is load-bearing)",
         ctx do
      # An empty worktree can still have committed history; retain that too.
      File.rm_rf!(ctx.work_dir)
      File.mkdir_p!(ctx.work_dir)
      git = fn args -> {_out, 0} = System.cmd("git", ["-C", ctx.work_dir | args]) end
      {_out, 0} = System.cmd("git", ["init", "-q", "-b", "ops", ctx.work_dir])

      File.write!(
        Path.join(ctx.work_dir, "history.md"),
        "committed, then removed from the worktree"
      )

      git.(["add", "-A"])
      git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "the work"])
      git.(["rm", "-q", "history.md"])

      assert {:ok, entries} = File.ls(ctx.work_dir)
      assert entries -- [".git"] == [], "fixture must look empty on disk"

      assert {:ok, %{local: %{ops: :kept_identity_unproven}}} =
               del(ctx, force: true, forge_repo: OkRepo)

      assert File.exists?(ctx.work_dir)
    end
  end

  describe "reconcile_main_protection/2 (periodic pass — only a SEEDED project is a target)" do
    defmodule ProbeRepo do
      # Reconciliation uses ops presence as a readiness heuristic, not proof of every onboarding step.
      def branch_exists?(repo, branch, _opts) do
        send(self(), {:branch_exists?, repo, branch})
        {:ok, repo in ["fleet/onboarded"]}
      end

      def protect_branch(repo, rule, _opts) do
        send(self(), {:protect_branch, repo, rule})
        {:ok, :created}
      end
    end

    defp reconcile(repo) do
      ProjectOnboard.Migration.reconcile_main_protection(repo,
        forge_repo: ProbeRepo,
        reviewer_roles: ["reviewer"]
      )
    end

    test "a repo whose seed push has NOT landed yet is left ALONE (the onboarding race)" do
      # Protecting main before its seed push would block creation; skip repos without the marker.
      assert :ok = reconcile("fleet/being-onboarded")
      refute_received {:protect_branch, _repo, _rule}
    end

    # No ops branch means skip protection, regardless of repository name.
    test "a repo without an `ops` face is not a project — nothing is protected" do
      assert :ok = reconcile("fleet/no-ops-face")
      refute_received {:protect_branch, _repo, _rule}
    end

    test "a seeded project still converges — the desired-state pass keeps its whole point" do
      assert :ok = reconcile("fleet/onboarded")

      assert_received {:protect_branch, "fleet/onboarded",
                       %{rule_name: "main", enable_push: false}}
    end

    # An unreadable marker must return an error, not the same success as an absent marker.
    defmodule UnreadableRepo do
      def branch_exists?(_repo, _branch, _opts), do: {:error, {:http, 503, "down"}}

      def protect_branch(repo, rule, _opts) do
        send(self(), {:protect_branch, repo, rule})
        {:ok, :created}
      end
    end

    test "JG-121: forge ILLISIBLE → erreur nommee, jamais un `:ok` qui vaut « rien a faire »" do
      assert {:error, {:seeded_unreadable, {:http, 503, "down"}}} =
               ProjectOnboard.Migration.reconcile_main_protection("fleet/unknowable",
                 forge_repo: UnreadableRepo,
                 reviewer_roles: ["reviewer"]
               )

      refute_received {:protect_branch, _repo, _rule},
                      "une regle a ete posee sur un depot dont on n'a pas su lire l'etat"
    end
  end

  describe "main-protection announcement (a forge move is traceable, a no-op is silent)" do
    defmodule OutcomeRepo do
      def branch_exists?(_repo, _branch, _opts), do: {:ok, true}
      def protect_branch(_repo, _rule, _opts), do: Process.get(:outcome)
    end

    defp reconcile_with(outcome) do
      Process.put(:outcome, {:ok, outcome})

      capture_log(fn ->
        assert :ok =
                 ProjectOnboard.Migration.reconcile_main_protection("fleet/proj",
                   forge_repo: OutcomeRepo,
                   reviewer_roles: ["reviewer", "qualifier"]
                 )
      end)
    end

    test "a rule PLACED is announced — the pass runs on a timer, so a forge move nobody asked for must leave a trace" do
      # Protection changes need an announcement; otherwise later push refusal is the only symptom.
      log = reconcile_with(:created)
      assert log =~ "fleet/proj main-protection created"
      assert log =~ "approvals=2"
    end

    test "a rule RESIZED is announced (the jury changed since onboarding)" do
      assert reconcile_with(:updated) =~ "fleet/proj main-protection updated"
    end

    test "an ALREADY-CONFORMANT rule says nothing — a nominal tick is silent" do
      # Match this repo's announcement, not global log emptiness: capture_log also sees concurrent logs.
      refute reconcile_with(:unchanged) =~ "fleet/proj main-protection"
    end
  end

  # Admission rejects names that Layout.project_slug would fold together; LayoutTest shares
  # the production pattern. These examples do not prove global uniqueness across catalogue orgs.
  describe "6-079 — la charte des noms, la garde dont depend l'unicite de l'espace projet" do
    test "un nom hors charte est REFUSE a la porte — les trois collisions de la fiche" do
      # Punctuation variants fold together. Uppercase is preserved by project_slug and tested separately.
      for name <- ["mon.projet", "mon_projet", "mon projet", "mon@projet"] do
        assert Fleet.Layout.project_slug("fleet/#{name}") == "mon-projet",
               "fixture #{inspect(name)} ne collisionne pas — le test ne prouverait rien"

        # Explicit org reaches name validation instead of failing catalogue admission first.
        assert {:error, {:invalid_name, ^name}} = ProjectOnboard.onboard(name, org: "fleet"),
               "#{inspect(name)} a franchi la porte : la collision de 6-079 devient atteignable"
      end
    end

    test "les formes de bord de la charte sont refusees aussi" do
      # Exercise invalid edges, uppercase and path segments.
      for name <- ["-x", "x-", "", "A", "Mon-Projet", "a/b", "../evil", "a b"] do
        # `org:` explicite : l'admission commune la refuserait AVANT le nom, et ce temoin mesure la
        # charte des noms, pas la declaration de catalogue.
        assert {:error, {:invalid_name, ^name}} = ProjectOnboard.onboard(name, org: "fleet"),
               "#{inspect(name)} accepte a la porte"
      end
    end

    # This call omits org and can fail before name validation; it is not a positive control
    # against an always-rejecting name guard.
    test "TEMOIN — un nom dans la charte passe la porte et echoue ailleurs" do
      for name <- ~w(mon-projet tetris a1 42) do
        case ProjectOnboard.onboard(name) do
          {:error, {:invalid_name, _}} ->
            flunk("#{inspect(name)} est dans la charte et se fait refuser sur son nom")

          _autre ->
            :ok
        end
      end
    end
  end

  describe "la declaration nomme SON depot — quatre portes, un entonnoir" do
    # Inspect the whole Onboard family after its split into submodules. This is a source-shape
    # check for a single repository-aware declaration writer; behavioral catalogue routing
    # is covered by project_declaration_test.exs.
    @onboard_src [
      "lib/fleet/project/onboard.ex" | Path.wildcard("lib/fleet/project/onboard/*.ex")
    ]

    defp famille, do: Enum.map_join(@onboard_src, "\n", &File.read!/1)

    test "aucune porte n'appelle `Declaration.write` en direct — toutes passent par l'entonnoir" do
      src = famille()

      assert length(Regex.scan(~r/Fleet\.Project\.Declaration\.write\(/, src)) == 1
      assert src =~ ~r/defp? write_declaration\(proj_dir, full_name, opts\)/
    end

    test "l'entonnoir POSE le depot dans les options — le lire ailleurs ne suffirait pas" do
      src = famille()

      # Force the actual repo over any stale option; put_new would preserve the wrong catalogue.
      assert src =~ ~r/Keyword\.put\(opts, :repo, full_name\)/
    end

    test "le depot est POSITIONNEL chez les relais — une cle optionnelle s'oublie en silence" do
      src = famille()

      # Required positional repo prevents omission at these call sites.
      assert src =~ ~r/defp? ensure_declaration\(\s*proj_dir,\s*full_name,\s*opts,/
      refute src =~ ~r/ensure_declaration\((?:dirs\.code|scratch), opts[,)]/
    end
  end

  describe "l'admission est UNE, pour les cinq verbes d'entree" do
    # Shared admission prevents the five entry points from independently drifting on card checks.
    @entry_verbs ~w(onboard import adopt_project import_external import_deposit)

    # Locate exactly one definition per file. The fixed character window can include a following
    # function; these substring assertions are not AST/control-flow checks.
    defp corps_du_verbe(verb) do
      motif = ~r/^  def #{verb}\(/m

      corps =
        for f <- famille_src(), source = File.read!(f), Regex.match?(motif, source) do
          [_, body] = String.split(source, motif, parts: 2)
          String.slice(body, 0, 1200)
        end

      case corps do
        [body] -> body
        [] -> flunk("`def #{verb}(` introuvable dans la famille onboarding")
        n -> flunk("`def #{verb}(` defini #{length(n)} fois : le temoin ne sait pas lequel lire")
      end
    end

    defp famille_src,
      do: ["lib/fleet/project/onboard.ex" | Path.wildcard("lib/fleet/project/onboard/*.ex")]

    test "les cinq verbes d'entree appellent `admit/3` — aucun ne refait le preambule" do
      for verb <- @entry_verbs do
        assert corps_du_verbe(verb) =~ "admit(",
               "#{verb}/n ne passe pas par l'admission commune — un sixieme preambule est ne"
      end
    end

    test "l'admission reste LOCALE — un refus pur ne coute pas un aller-retour forge" do
      # This substring check excludes one former forge helper from the admission preamble;
      # it does not prove the absence of every possible forge call.
      refute String.slice(corps_du_verbe("admit"), 0, 400) =~ "ensure_human_provisioned",
             "l'admission touche la forge — un refus local en paie le prix"
    end
  end
end
