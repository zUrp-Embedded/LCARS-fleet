defmodule Fleet.Pilot.ProjectOnboardTest do
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

  alias Fleet.Pilot.ProjectOnboard

  describe "classify_create_repo/3 (F-C084 — pre-existing repo is not an onboard target)" do
    test "genuine CREATE ({:ok, full_name}) → {:ok, full_name} (onboard owns the fresh repo)" do
      assert {:ok, "fleet/neuf"} =
               ProjectOnboard.classify_create_repo({:ok, "fleet/neuf"}, "fleet", "neuf")
    end

    test "repo ALREADY existing (409 → {:ok, :already_exists}) → {:error, {:repo_already_exists, _}} (FAIL-LOUD)" do
      # Core of the finding: treating already_exists as SUCCESS would make onboard clone + scaffold +
      # push onto the existing `main` = silent CLOBBER. Fail-loud instead → the operator uses
      # import_project (adopts, content intact) or deletes the stale/partial repo.
      assert {:error, {:repo_already_exists, "fleet/deja"}} =
               ProjectOnboard.classify_create_repo({:ok, :already_exists}, "fleet", "deja")
    end

    test "forge error propagated as-is (no interpretation)" do
      assert {:error, {:http, 500, "boom"}} =
               ProjectOnboard.classify_create_repo({:error, {:http, 500, "boom"}}, "fleet", "x")
    end
  end

  describe "delete_project/2 (general project teardown — FAIL-CLOSED, CI-07)" do
    defmodule OkRepo do
      def default_branch(_repo, _opts), do: {:ok, "main"}
      def delete_repo(repo, _opts), do: send(self(), {:delete_repo, repo}) && :ok
    end

    defmodule AbsentRepo do
      def default_branch(_repo, _opts), do: {:error, {:http, 404, "no repo"}}
      def delete_repo(repo, _opts), do: send(self(), {:delete_repo, repo}) && :ok
    end

    defmodule OutageRepo do
      def default_branch(_repo, _opts), do: {:error, {:http, 500, "boom"}}
      def delete_repo(repo, _opts), do: send(self(), {:delete_repo, repo}) && :ok
    end

    defmodule OkSpawner do
      def kill_pod(pod_id), do: send(self(), {:kill_pod, pod_id}) && :ok
    end

    defmodule NoArchSpawner do
      def kill_pod(_pod_id), do: {:error, :not_found}
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
      work_root = Path.join(tmp, "work")
      doc_root = Path.join(tmp, "doc")
      proj_dir = Path.join(proj_root, "demo")
      work_dir = Path.join(work_root, "demo")
      doc_dir = Path.join(doc_root, "demo")
      # The local `demo` belongs to fleet/demo (origin says so) — on all three faces.
      init_repo_with_origin(proj_dir, "https://forge.test/fleet/demo.git")
      init_repo_with_origin(work_dir, "https://forge.test/fleet/demo.git")
      init_repo_with_origin(doc_dir, "https://forge.test/fleet/demo.git")

      {:ok,
       proj_root: proj_root,
       work_root: work_root,
       doc_root: doc_root,
       proj_dir: proj_dir,
       work_dir: work_dir,
       doc_dir: doc_dir}
    end

    defp del(ctx, extra) do
      ProjectOnboard.delete_project(
        "fleet/demo",
        Keyword.merge(
          [
            projects_root: ctx.proj_root,
            work_root: ctx.work_root,
            doc_root: ctx.doc_root,
            spawner: OkSpawner
          ],
          extra
        )
      )
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
                local: %{project: :kept_identity_unproven, work: :kept_identity_unproven}
              }} =
               ProjectOnboard.delete_project(
                 "other/demo",
                 projects_root: ctx.proj_root,
                 work_root: ctx.work_root,
                 doc_root: ctx.doc_root,
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

      assert {:ok, %{forge: :deleted, local: %{project: :kept_identity_unproven, work: :removed}}} =
               del(ctx, force: true, forge_repo: OkRepo)

      assert File.exists?(ctx.proj_dir)
      refute File.exists?(ctx.work_dir)
    end

    @tag :tmp_dir
    test "force + NO origin + provably empty → removed as onboard debris (the wedge is gone)",
         ctx do
      # The exact residue a crash between `git init -b work/ops` and `remote add origin` leaves:
      # a git repo, no origin, nothing in it. Refusing to remove it protected nothing and wedged the
      # next onboard on `refute_existing`, with a host-side `rm` as the only way out.
      File.rm_rf!(ctx.work_dir)
      File.mkdir_p!(ctx.work_dir)
      {_out, 0} = System.cmd("git", ["init", "-q", "-b", "work/ops", ctx.work_dir])

      assert {:ok, %{local: %{project: :removed, work: :removed}}} =
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
      {_out, 0} = System.cmd("git", ["init", "-q", "-b", "work/ops", ctx.work_dir])
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

      assert {:ok, %{local: %{work: :kept_identity_unproven}}} =
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
      {_out, 0} = System.cmd("git", ["init", "-q", "-b", "work/ops", ctx.work_dir])
      File.write!(Path.join(ctx.work_dir, "draft.md"), "uncommitted, still someone's")

      assert {:ok, %{local: %{work: :kept_identity_unproven}}} =
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
      {_out, 0} = System.cmd("git", ["init", "-q", "-b", "work/ops", ctx.work_dir])

      File.write!(
        Path.join(ctx.work_dir, "history.md"),
        "committed, then removed from the worktree"
      )

      git.(["add", "-A"])
      git.(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "the work"])
      git.(["rm", "-q", "history.md"])

      assert {:ok, entries} = File.ls(ctx.work_dir)
      assert entries -- [".git"] == [], "fixture must look empty on disk"

      assert {:ok, %{local: %{work: :kept_identity_unproven}}} =
               del(ctx, force: true, forge_repo: OkRepo)

      assert File.exists?(ctx.work_dir)
    end
  end

  describe "reconcile_main_protection/2 (periodic pass — only a SEEDED project is a target)" do
    defmodule ProbeRepo do
      # `work/ops` is pushed AFTER `main` by both onboard and import, so its presence on the forge
      # PROVES the seed push already landed. Driven here by the repo name.
      def branch_exists?(repo, branch, _opts) do
        send(self(), {:branch_exists?, repo, branch})
        repo in ["fleet/onboarded", "fleet/project-template"]
      end

      def protect_branch(repo, rule, _opts) do
        send(self(), {:protect_branch, repo, rule})
        {:ok, :created}
      end
    end

    defp reconcile(repo) do
      ProjectOnboard.reconcile_main_protection(repo,
        forge_repo: ProbeRepo,
        project_template: "fleet/project-template",
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

    test "the project TEMPLATE is never protected (its sync FORCE-pushes main)" do
      # The template carries a `work/ops` face of its own, so the seeded-project test alone would
      # let it through. `mix lcars.project_template.sync` force-pushes both faces: a protected
      # `main` breaks the projection that every new project is generated from.
      assert :ok = reconcile("fleet/project-template")
      refute_received {:protect_branch, _repo, _rule}
    end

    test "a seeded project still converges — the desired-state pass keeps its whole point" do
      assert :ok = reconcile("fleet/onboarded")

      assert_received {:protect_branch, "fleet/onboarded",
                       %{rule_name: "main", enable_push: false}}
    end
  end

  describe "main-protection announcement (a forge move is traceable, a no-op is silent)" do
    defmodule OutcomeRepo do
      def branch_exists?(_repo, _branch, _opts), do: true
      def protect_branch(_repo, _rule, _opts), do: Process.get(:outcome)
    end

    defp reconcile_with(outcome) do
      Process.put(:outcome, {:ok, outcome})

      capture_log(fn ->
        assert :ok =
                 ProjectOnboard.reconcile_main_protection("fleet/proj",
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
end
