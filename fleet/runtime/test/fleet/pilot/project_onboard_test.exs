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

    setup %{tmp_dir: tmp} do
      proj_root = Path.join(tmp, "projects")
      work_root = Path.join(tmp, "work")
      proj_dir = Path.join(proj_root, "demo")
      work_dir = Path.join(work_root, "demo")
      File.mkdir_p!(proj_dir)
      File.mkdir_p!(work_dir)
      {:ok, proj_root: proj_root, work_root: work_root, proj_dir: proj_dir, work_dir: work_dir}
    end

    defp del(ctx, extra) do
      ProjectOnboard.delete_project(
        "fleet/demo",
        Keyword.merge(
          [projects_root: ctx.proj_root, work_root: ctx.work_root, spawner: OkSpawner],
          extra
        )
      )
    end

    @tag :tmp_dir
    test "WITHOUT force → {:error, force_required}, touches NOTHING (fail-closed, no valueless heuristic)", ctx do
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
  end
end
