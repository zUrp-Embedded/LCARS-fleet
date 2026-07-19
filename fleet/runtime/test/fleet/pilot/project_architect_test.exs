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

  test "open/2 spawns the architect PROJECT-BOUND (composed cap + repo_id + rc_name + clone URL)" do
    assert {:ok, "architect-demo"} =
             ProjectArchitect.open(
               %{repo: "fleet/demo", url: "https://forge.local/fleet/demo.git", name: "demo"},
               spawner: CaptureSpawner,
               forge_client: StubForge
             )

    assert_received {:spawn_pod, cap, issue_id, opts}

    # The composed architect cap (default modops applied).
    assert Fleet.CapProfile.name(cap) == "architect"
    # Deterministic per-project pod_id (relaunch-idempotent), NOT a permanent-* id.
    assert opts[:pod_id] == "architect-demo"
    assert issue_id == "architect-fleet/demo"
    # Project-bound: numeric repo id → the <REPO4> of the deterministic UUID.
    assert opts[:repo_id] == 4242
    # One Desktop slot per project.
    assert opts[:rc_name] == "demo_architect"
    # Clone-from-URL like any worker (repo_path = git URL, base main).
    assert opts[:project]["repo_path"] == "https://forge.local/fleet/demo.git"
    assert opts[:project]["base_branch"] == "main"
  end

  test "open/2: a spawn failure is returned (non-fatal — the caller onboard ignores it)" do
    assert {:error, :launch_failed} =
             ProjectArchitect.open(
               %{repo: "fleet/demo", url: "https://forge.local/fleet/demo.git", name: "demo"},
               spawner: FailSpawner,
               forge_client: StubForge
             )
  end
end
