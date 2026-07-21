defmodule Fleet.Pilot.ProjectArchitectTest do
  # async: false — captures the spawn call via an app-env pid (global).
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ProjectArchitect

  @cap_key :test_project_architect_capture_pid

  defmodule StubForge do
    # Numeric forge id resolution (resolve_repo_id → forge.repo_id/2).
    def repo_id("fleet/demo", _opts), do: {:ok, 4242}
    def repo_id(_repo, _opts), do: {:error, :not_found}
  end

  defmodule CaptureSpawner do
    def spawn_pod(cap, issue_id, opts) do
      send(
        Application.fetch_env!(:lcars_fleet, :test_project_architect_capture_pid),
        {:spawn_pod, cap, issue_id, opts}
      )

      {:ok, spawn(fn -> :ok end)}
    end
  end

  defmodule FailSpawner do
    def spawn_pod(_cap, _issue_id, _opts), do: {:error, :launch_failed}
  end

  setup do
    Application.put_env(:lcars_fleet, @cap_key, self())
    on_exit(fn -> Application.delete_env(:lcars_fleet, @cap_key) end)
    :ok
  end

  test "pod_id_for/1 — THE per-project authority (full_name or bare name)" do
    assert ProjectArchitect.pod_id_for("fleet/demo") == "architect-demo"
    assert ProjectArchitect.pod_id_for("demo") == "architect-demo"
  end

  describe "ensure/2" do
    @describetag :tmp_dir

    # The project's dual-dir on the machine (ensure refuses an absent project — its mounts ARE its world).
    defp mk_dirs(tmp) do
      proj = Path.join([tmp, "projects", "demo"])
      work = Path.join([tmp, "projects.work", "demo"])
      File.mkdir_p!(proj)
      File.mkdir_p!(work)

      {proj, work,
       [projects_root: Path.join(tmp, "projects"), work_root: Path.join(tmp, "projects.work")]}
    end

    test "spawns the architect PROJECT-BOUND: composed cap + repo_id + repo + rc_name + MOUNTS (no clone)",
         %{tmp_dir: tmp} do
      {proj, work, roots} = mk_dirs(tmp)

      assert {:ok, "architect-demo"} =
               ProjectArchitect.ensure(
                 "fleet/demo",
                 [spawner: CaptureSpawner, forge_client: StubForge] ++ roots
               )

      assert_received {:spawn_pod, cap, _issue_id, opts}

      # The composed architect cap (default modops applied).
      assert Fleet.CapProfile.name(cap) == "architect"
      # Deterministic per-project pod_id (relaunch-idempotent), via the single authority.
      assert opts[:pod_id] == "architect-demo"

      # Identity: numeric repo id → the <REPO4> of the deterministic UUID; `repo` = the channel-side
      # binding pod_info exposes (the repo-implicit MCP tools resolve "the project" from it).
      assert opts[:repo_id] == 4242
      assert opts[:repo] == "fleet/demo"
      # One Desktop slot per project.
      assert opts[:rc_name] == "demo_architect"
      # NO CLONE (§14.d): the arch is not a producer — its world is the two live host dirs.
      refute Keyword.has_key?(opts, :project)

      assert opts[:mounts] == [
               %{"mode" => "ro", "path" => proj},
               %{"mode" => "rw", "path" => work}
             ]
    end

    test "project NOT on the machine → {:error, {:not_onboarded, _}} — no spawn", %{tmp_dir: tmp} do
      assert {:error, {:not_onboarded, _}} =
               ProjectArchitect.ensure(
                 "fleet/demo",
                 spawner: CaptureSpawner,
                 forge_client: StubForge,
                 projects_root: Path.join(tmp, "projects"),
                 work_root: Path.join(tmp, "projects.work")
               )

      refute_received {:spawn_pod, _, _, _}
    end

    test "numeric repo id unresolved (forge down) → clear refusal, no spawn", %{tmp_dir: tmp} do
      {_proj, _work, roots} = mk_dirs(tmp)

      defmodule NoIdForge do
        def repo_id(_repo, _opts), do: {:error, :forge_down}
      end

      # dirs exist for "demo" but the forge cannot resolve fleet/demo… use a repo the stub refuses.
      assert {:error, {:repo_id_unresolved, "fleet/demo"}} =
               ProjectArchitect.ensure(
                 "fleet/demo",
                 [spawner: CaptureSpawner, forge_client: NoIdForge] ++ roots
               )

      refute_received {:spawn_pod, _, _, _}
    end

    test "a spawn failure is returned (best-effort at call sites)", %{tmp_dir: tmp} do
      {_proj, _work, roots} = mk_dirs(tmp)

      assert {:error, :launch_failed} =
               ProjectArchitect.ensure(
                 "fleet/demo",
                 [spawner: FailSpawner, forge_client: StubForge] ++ roots
               )
    end
  end
end
