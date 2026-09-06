defmodule Fleet.Project.OnboardTest do
  @moduledoc """
  F-C084 — `onboard/2` CREATES a fresh project: it scaffolds `main` + pushes over it. A PRE-EXISTING
  repo is NOT a safe target (clobbering the `main` of a real repo: a human's repo onboarded by mistake,
  or a complete project re-onboarded). The PURE decision `classify_create_repo/3` fails loud on
  `{:ok, :already_exists}` (create_repo 409); only a genuine CREATE proceeds. `create_repo` sits at the
  HEAD of onboard's `with` (before clone/scaffold/push) → the error short-circuits the sequence by
  construction: nothing is written to the existing repo. (Adopting an existing repo goes through
  `import/2`, which does NOT scaffold `main`.)
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
      # Core of the finding: treating already_exists as SUCCESS would make onboard clone + scaffold +
      # push onto the existing `main` = silent CLOBBER. Fail-loud instead → the operator uses
      # import_project (adopts, content intact) or deletes the stale/partial repo.
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

    # Onboarded dirs are git repos whose `remote.origin.url` records the FULL identity (owner/name) —
    # the marker delete uses to prove a local dir IS the target and is not a same-basename homonym.
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
      # The local `demo` belongs to fleet/demo (origin says so) — on all three faces.
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
      # An engineer in flight used to outlive the removal of its own project: only the architect
      # was stopped. Its workspace still existed so it did not even crash — it kept reading a
      # reference that was gone. And a deletion that cost work in flight must not read as free.
      assert {:ok, result} = del(ctx, force: true, forge_repo: OkRepo)

      assert_received {:swept, "fleet/demo"}
      assert result.workers_killed == 2
    end

    @tag :tmp_dir
    test "WITHOUT force → {:error, force_required}, touches NOTHING (fail-closed, no valueless heuristic)",
         ctx do
      # An imported repo has real content but ZERO fleet issues/PRs → any "0 activity = nuke" guard would
      # DESTROY it. So delete is fail-closed: no force, no destruction, no forge call, dirs intact.
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
      # The owner-typo footgun: `other/demo` does not exist on the forge (404), and the local `demo`
      # dirs belong to `fleet/demo` (their git origin says so). Deleting `other/demo` must NOT destroy
      # fleet/demo's local project just because it shares the basename.
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

      # The homonym's architect is NEVER stopped, and fleet/demo's local project survives intact.
      refute_received {:kill_pod, _}
      assert File.exists?(ctx.proj_dir)
      assert File.exists?(ctx.work_dir)
    end

    @tag :tmp_dir
    test "force + right owner but local origin is a DIFFERENT project → that dir KEPT (basename collision)",
         ctx do
      # proj_dir's origin is another owner's repo (a stale/mis-provisioned dir sharing the basename).
      # Even with the correct target and force, a dir whose origin ≠ target is never nuked.
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
      # The exact residue a crash between `git init -b ops` and `remote add origin` leaves:
      # a git repo, no origin, nothing in it. Refusing to remove it protected nothing and wedged the
      # next onboard on `refute_existing`, with a host-side `rm` as the only way out.
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
      # The adverse half of the proof above: no origin is NOT sufficient. A repo carrying commits is
      # somebody's local-only work at that path — genuinely ambiguous, and emptiness is what separates
      # the two. Proving debris must never degrade into "no origin, therefore expendable".
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
      # `git init` alone answers "no commit" while a half-written scaffold still sits on disk. If the
      # emptiness proof were the commit check alone, this dir would be erased with its content.
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
      # The symmetric half: content committed then removed from the worktree leaves a dir that LOOKS
      # empty on disk while its history holds the work. Listing the directory cannot see that; only the
      # commit check can. Erasing this would destroy the history it is made of.
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
      # `ops` is pushed AFTER `main` by both onboard and import, so its presence on the forge
      # PROVES the seed push already landed. Driven here by the repo name.
      # JG-121 — trois etats : `{:ok, bool}` sur une lecture aboutie. Le cas illisible a son test.
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
      # The window: create_repo puts the repo in the org (org-membership IS the poller's
      # discovery) SECONDS before onboard pushes `main`. Protecting `main` inside that window
      # makes the forge refuse the seed push itself — the project can never be created. The
      # periodic pass must therefore never touch a repo it did not witness finish.
      assert :ok = reconcile("fleet/being-onboarded")
      refute_received {:protect_branch, _repo, _rule}
    end

    # ⚠ LE TEMOIN DU DEPOT MODELE EST PARTI AVEC LUI (2026-08-21). Il epinglait que
    # `fleet/project-template` n'etait jamais protege : son sync force-poussait `main`, et une
    # protection aurait casse la projection dont tout projet neuf etait genere. Ce depot n'existe
    # plus — le squelette vient du catalogue sur disque.
    #
    # Ce qui garde sa place est plus large et ne nomme rien : un depot sans branche `ops` n'est pas
    # un projet, quel que soit son nom. Le magasin d'un catalogue n'en porte pas.
    test "a repo without an `ops` face is not a project — nothing is protected" do
      assert :ok = reconcile("fleet/no-ops-face")
      refute_received {:protect_branch, _repo, _rule}
    end

    test "a seeded project still converges — the desired-state pass keeps its whole point" do
      assert :ok = reconcile("fleet/onboarded")

      assert_received {:protect_branch, "fleet/onboarded",
                       %{rule_name: "main", enable_push: false}}
    end

    # JG-121 — ET LE DEFAUT NE PASSAIT MEME PAS PAR UN CHEMIN D'ERREUR. `branch_exists?` rendait
    # `false` sur une forge illisible, donc cette fonction partait dans son `else` et rendait `:ok` :
    # « rien a faire ici », mot pour mot ce que rend un depot legitimement non seede. Le Poller
    # horodatait alors le depot comme reconcilie, la protection de `main` n'etait jamais posee, et
    # RIEN ne le disait — ni log, ni erreur, ni difference observable.
    #
    # La fonction voisine dans le meme module, `user_exists?/2`, distingue depuis toujours un 404
    # prouve d'une panne. Huit lignes plus bas.
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
      # This is the whole point: the periodic pass can put `enable_push: false` on a repo at any
      # tick. Silent, that mutation is invisible from inside the fleet and only its consequences
      # are observable (a push refused somewhere else, much later).
      log = reconcile_with(:created)
      assert log =~ "fleet/proj main-protection created"
      assert log =~ "approvals=2"
    end

    test "a rule RESIZED is announced (the jury changed since onboarding)" do
      assert reconcile_with(:updated) =~ "fleet/proj main-protection updated"
    end

    test "an ALREADY-CONFORMANT rule says nothing — a nominal tick is silent" do
      # The other half of the rule: one line per repo per period saying 'still fine' would bury
      # the one line that matters under noise it produced itself.
      #
      # Anchored on the announcement, NOT on global emptiness: capture_log/1 collects the WHOLE
      # VM's Logger output, so in an async suite any unrelated module logging inside this window
      # turns `== ""` red. That verdict comes from the scheduler, not from the code under test —
      # and a wall that answers at random gives a green having exercised nothing. The claim here
      # is narrow and belongs to this call: reconcile announced NO main-protection for this repo.
      refute reconcile_with(:unchanged) =~ "fleet/proj main-protection"
    end
  end

  # 6-079 — LA PORTE DONT DEPEND TOUTE LA NON-COLLISION N'ETAIT TENUE PAR RIEN.
  #
  # `Fleet.Layout.project_slug/1` n'est PAS injective : elle replie tout ce qui sort de
  # `[A-Za-z0-9-]` sur un `-`, donc `mon.projet`, `mon_projet` et `Mon-Projet` rendent le meme
  # `mon-projet`. La fiche en deduit que deux depots distincts partagent un espace de projet sur
  # disque. **Mesure : c'est inatteignable**, et la chaine a QUATRE maillons :
  #
  #   1. le Poller ne sert un depot que si `<ops_root>/<project_name>` existe (`onboarded?/1`) ;
  #   2. ce repertoire ne nait que d'un onboarding, dont la PREMIERE etape est `validate_name` ;
  #   3. dans la charte `^[a-z0-9][a-z0-9-]*[a-z0-9]$`, `project_name == project_slug` ;
  #   4. donc deux projets SERVIS qui collisionnent auraient le meme nom.
  #
  # Le maillon 3 est epingle par `Fleet.LayoutTest` (avec son temoin anti-vacuite), et 6-078 en a
  # ferme une moitie voisine. **Le maillon 2 ne l'etait pas** : huit sites appellent
  # `validate_name`, et `{:invalid_name, _}` n'apparaissait dans AUCUN test. L'argument entier
  # reposait sur une garde que rien n'obligeait a rester.
  #
  # Aucun reseau ici : `validate_name` est la premiere clause du `with` d'`onboard/2`, donc le refus
  # tombe avant le moindre appel forge.
  describe "6-079 — la charte des noms, la garde dont depend l'unicite de l'espace projet" do
    test "un nom hors charte est REFUSE a la porte — les trois collisions de la fiche" do
      # Les trois replient sur `mon-projet` par `project_slug/1`. Aucune n'entre.
      #
      # ⚠ `Mon-Projet` N'EST PAS dans cette liste, et la garde de fixture ci-dessous me l'a appris :
      # `project_slug/1` replie `[^A-Za-z0-9-]`, donc elle CONSERVE la majuscule et `Mon-Projet` ne
      # collisionne avec rien. La divergence sur la casse existe, mais c'est celle de 6-078 (le
      # producteur rend un slug que `Fleet.Slug` refuse), pas celle-ci. Le nom part au test de bord.
      for name <- ["mon.projet", "mon_projet", "mon projet", "mon@projet"] do
        assert Fleet.Layout.project_slug("fleet/#{name}") == "mon-projet",
               "fixture #{inspect(name)} ne collisionne pas — le test ne prouverait rien"

        # `org:` explicite : l'admission commune la refuserait AVANT le nom, et ce temoin mesure la
        # charte des noms, pas la declaration de catalogue.
        assert {:error, {:invalid_name, ^name}} = ProjectOnboard.onboard(name, org: "fleet"),
               "#{inspect(name)} a franchi la porte : la collision de 6-079 devient atteignable"
      end
    end

    test "les formes de bord de la charte sont refusees aussi" do
      # Tiret en tete/queue, vide, majuscule seule, segment de chemin : la charte exige un
      # alphanumerique aux DEUX bouts, et c'est ce qui interdit `../` et les noms d'un caractere
      # non alphanumerique.
      for name <- ["-x", "x-", "", "A", "Mon-Projet", "a/b", "../evil", "a b"] do
        # `org:` explicite : l'admission commune la refuserait AVANT le nom, et ce temoin mesure la
        # charte des noms, pas la declaration de catalogue.
        assert {:error, {:invalid_name, ^name}} = ProjectOnboard.onboard(name, org: "fleet"),
               "#{inspect(name)} accepte a la porte"
      end
    end

    # TEMOIN — sans lui, un `onboard/2` qui refuserait TOUT passerait les deux tests ci-dessus, et
    # la garde qu'ils pretendent tenir serait vide. Un nom onboardable doit echouer PLUS LOIN
    # (forge absente en test), jamais sur son nom.
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
    # ⚠ TEMOIN DE FORME, ET C'EST DELIBERE — il faut le dire, pas le maquiller. Les quatre portes
    # d'ecriture (`finish_onboard`, `finish_adopt`, `finish_external`, `revise`) exigent chacune un
    # depot forge vivant : les jouer demanderait une doublure de forge que ce module n'a pas. Ce qui
    # EST epinglable sans elle, c'est qu'aucune ne puisse plus ecrire une declaration sans nommer le
    # depot — et c'est precisement la propriete dont l'absence a produit le defaut quatre fois.
    #
    # MESURE DU 2026-08-20 : le guichet presente les cartes de `web-demo`, l'agent en choisit une,
    # `project_create` refuse en enumerant celles de `fleet`. Le prefiltre resolvait dans le
    # catalogue du projet, l'ecriture dans la racine.
    #
    # Le comportement de l'aiguillage lui-meme, lui, est mesure — cf. `project_declaration_test.exs`,
    # « write/2 resout la carte dans le catalogue DU DEPOT qu'on lui nomme ».
    # ⚠ LA FAMILLE, PAS UN FICHIER. Ces temoins lisaient `onboard.ex` seul ; au decoupage, quatre
    # des cinq portes ont change de module et deux d'entre eux ont vire au rouge. Un temoin de
    # SOURCE dit une propriete du CODE, pas d'une adresse : il lit donc tout l'arbre du domaine, et
    # `familie_src/0` est la seule definition de ce perimetre.
    @onboard_src [
      "lib/fleet/project/onboard.ex" | Path.wildcard("lib/fleet/project/onboard/*.ex")
    ]

    defp famille, do: Enum.map_join(@onboard_src, "\n", &File.read!/1)

    test "aucune porte n'appelle `Declaration.write` en direct — toutes passent par l'entonnoir" do
      src = famille()

      # Un seul appel direct subsiste : celui QUI EST l'entonnoir. Deux voudraient dire qu'une porte
      # a repris le chemin court, et le chemin court est celui qui oublie.
      assert length(Regex.scan(~r/Fleet\.Project\.Declaration\.write\(/, src)) == 1
      assert src =~ ~r/defp? write_declaration\(proj_dir, full_name, opts\)/
    end

    test "l'entonnoir POSE le depot dans les options — le lire ailleurs ne suffirait pas" do
      src = famille()

      # ⚠ `Keyword.put`, PAS `put_new` : `revision_write_opts/2` reconstruit une liste neuve, et un
      # appelant qui porterait un `repo:` perime le ferait gagner sur le depot reel.
      assert src =~ ~r/Keyword\.put\(opts, :repo, full_name\)/
    end

    test "le depot est POSITIONNEL chez les relais — une cle optionnelle s'oublie en silence" do
      src = famille()

      # C'est toute la difference entre ce correctif et un quatrieme rustine : le compilateur refuse
      # desormais un appel qui ne nomme pas le depot. `Declaration.write/2` ne peut pas l'exiger de son
      # cote — 38 appels legitimes prennent la racine a bon droit — mais ici, l'omettre est TOUJOURS
      # un defaut.
      assert src =~ ~r/defp? ensure_declaration\(\s*proj_dir,\s*full_name,\s*opts,/
      refute src =~ ~r/ensure_declaration\((?:dirs\.code|scratch), opts[,)]/
    end
  end

  describe "l'admission est UNE, pour les cinq verbes d'entree" do
    # ⚖ user, 2026-08-17 : « on a des rails paralleles qui font la meme chose, alors qu'on devrait
    # avoir une seule fonction parametrique » — et « ca serait vachement plus facile a fixer si tous
    # les verbes passaient par le meme filtre ». Mis cote a cote, les cinq preambules posaient les
    # memes questions, et `import/2` etait le SEUL a ne pas verifier que la carte est declarable.
    # Personne ne l'avait vu parce que personne ne les avait alignes : des rails paralleles ne
    # divergent pas d'un coup, ils divergent d'UNE ligne.
    #
    # CE TEMOIN LIT LA SOURCE, et c'est le seul moyen d'epingler « tous passent par la meme porte » :
    # exercer les cinq demanderait cinq mondes (forge, depots, URL externes), et c'est precisement
    # ce cout qui a laisse la divergence s'installer.
    @entry_verbs ~w(onboard import adopt_project import_external import_deposit)

    # ⚠ PAR FICHIER, JAMAIS SUR UNE SOURCE CONCATENEE. La premiere version collait toute la famille
    # puis coupait au verbe : la fenetre de lecture debordait alors sur la fonction SUIVANTE, voire
    # sur le fichier suivant, et le motif cherche pouvait etre trouve chez un voisin. `door_preamble/1`
    # de `store_gate_test` avait deja la bonne forme — celle-ci ne l'avait pas copiee.
    #
    # Zero comme plusieurs definitions font FLUNK : un temoin de source qui ne sait pas lequel des
    # deux corps il lit ne prouve rien, et le silence est le pire des deux.
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
      # ⚠ LA PREMIERE VERSION Y AVAIT MIS `ensure_human_provisioned/2`, qui appelle la forge, et un
      # temoin l'a montre dans la minute : une URL externe invalide, refusee jusque-la sans toucher
      # le monde, coutait desormais un appel forge. La loi d'ordre est en trois temps — admission
      # locale, gardes pures du verbe, puis le monde — et c'est ce que ce temoin tient.
      refute String.slice(corps_du_verbe("admit"), 0, 400) =~ "ensure_human_provisioned",
             "l'admission touche la forge — un refus local en paie le prix"
    end
  end
end
