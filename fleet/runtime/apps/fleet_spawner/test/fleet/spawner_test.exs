defmodule Fleet.SpawnerTest do
  use ExUnit.Case, async: false

  alias Fleet.Spawner.LaunchBackend.StubBackend

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_spawner, :state_fs_root, Path.join(tmp_dir, "state"))
    Application.put_env(:fleet_spawner, :pod_dir_root, Path.join(tmp_dir, "pods"))
    Application.put_env(:fleet_spawner, :launch_backend, StubBackend)

    coffre = Path.join(tmp_dir, "coffre")
    Application.put_env(:fleet_credentials, :creds_root, coffre)
    File.mkdir_p!(Path.join(coffre, "engineer"))
    File.write!(Path.join([coffre, "engineer", "oauth_refresh_token"]), "rt")
    File.write!(Path.join([coffre, "engineer", "oauth_access_token"]), "at")

    File.write!(
      Path.join([coffre, "engineer", "oauth_scopes"]),
      "user:inference user:sessions:claude_code"
    )

    sp_root = Path.join(tmp_dir, "cap-profiles")
    File.mkdir_p!(sp_root)
    File.write!(Path.join(sp_root, "engineer-role.md"), "# SP")
    Application.put_env(:fleet_spbuilder, :sp_role_root, sp_root)

    StubBackend.set_reply(
      {:ok,
       %{
         init_message: StubBackend.valid_init_message(),
         ndjson_log: "/tmp/stub.ndjson"
       }}
    )

    on_exit(fn ->
      StubBackend.clear()
      Application.delete_env(:fleet_spawner, :state_fs_root)
      Application.delete_env(:fleet_spawner, :pod_dir_root)
      # B5 #576 : NE PAS delete :launch_backend — laisse la baseline
      # hermétique config/test.exs (StubBackend) en place, sinon le
      # code-default PortBackend RÉEL est atteint sous race async.
      Application.delete_env(:fleet_credentials, :creds_root)
      Application.delete_env(:fleet_spbuilder, :sp_role_root)
    end)

    :ok
  end

  defp valid_profile do
    %Fleet.CapProfile{
      api_version: "lcars/v2.5",
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer", "containment" => "bwrap"},
      spec: %{
        "systemPrompt" => "engineer-role.md",
        "scope" => %{"disallowedTools" => [], "git_ops_denied" => []},
        "knowledge" => %{"skills" => []},
        "invocation" => %{"lifetime_scope" => "one-shot", "max_alive_sec" => 60},
        "injects" => %{},
        "budget" => %{"maxUsd" => 1.0, "maxDurationSec" => 60},
        "modop_set" => []
      }
    }
  end

  test "spawn_pod returns {:ok, pid} and registers the pod" do
    pod_id = "pod-public-api-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = Fleet.Spawner.spawn_pod(valid_profile(), "ticket-1", pod_id: pod_id)
    assert is_pid(pid)
    Process.sleep(50)
    assert {:ok, %{pod_id: ^pod_id}} = Fleet.Spawner.pod_info(pod_id)
  end

  test "pod_info returns :not_found when pod doesn't exist" do
    assert {:error, :not_found} = Fleet.Spawner.pod_info("nonexistent-pod-id")
  end

  test "kill_pod terminates the pod" do
    pod_id = "pod-kill-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Fleet.Spawner.spawn_pod(valid_profile(), "ticket-2", pod_id: pod_id)
    Process.sleep(50)

    assert :ok = Fleet.Spawner.kill_pod(pod_id)
    Process.sleep(50)
    assert {:error, :not_found} = Fleet.Spawner.pod_info(pod_id)
  end

  test "kill_pod :not_found for unknown pod_id" do
    assert {:error, :not_found} = Fleet.Spawner.kill_pod("never-spawned")
  end

  test "spawn_pod uses UUID by default if no :pod_id opt given" do
    {:ok, pid1} = Fleet.Spawner.spawn_pod(valid_profile(), "ticket-uuid-1")
    {:ok, pid2} = Fleet.Spawner.spawn_pod(valid_profile(), "ticket-uuid-2")
    assert pid1 != pid2
  end

  test "count_pods returns the number of active pods" do
    initial = Fleet.Spawner.count_pods()
    assert is_integer(initial)
    assert initial >= 0

    pod_id = "pod-count-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Fleet.Spawner.spawn_pod(valid_profile(), "ticket-count", pod_id: pod_id)
    Process.sleep(20)

    assert Fleet.Spawner.count_pods() >= initial + 1
  end
end
