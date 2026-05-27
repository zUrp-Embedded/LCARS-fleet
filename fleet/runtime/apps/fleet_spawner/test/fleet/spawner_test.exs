defmodule Fleet.SpawnerTest do
  use ExUnit.Case, async: false

  alias Fleet.Spawner.LaunchBackend.StubBackend

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:fleet_spawner, :state_fs_root, Path.join(tmp_dir, "state"))
    Application.put_env(:fleet_spawner, :pod_dir_root, Path.join(tmp_dir, "pods"))
    Application.put_env(:fleet_spawner, :launch_backend, StubBackend)
    # adr-f : plus de coffre (creds via claudeDir bind bwrap).

    sp_root = Path.join(tmp_dir, "cap-profiles")
    File.mkdir_p!(sp_root)
    File.write!(Path.join(sp_root, "engineer-role.md"), "# SP")
    Application.put_env(:fleet_sp_builder, :sp_role_root, sp_root)

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
      # code-default LauncherPortBackend RÉEL est atteint sous race async.
      Application.delete_env(:fleet_credentials, :creds_root)
      Application.delete_env(:fleet_sp_builder, :sp_role_root)
    end)

    :ok
  end

  defp valid_profile do
    %Fleet.CapProfile{
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

    # Mi14 : registration synchrone (name: {:via, Registry, ...}) → pod enregistré dès {:ok, pid}.
    assert {:ok, %{pod_id: ^pod_id}} = Fleet.Spawner.pod_info(pod_id)
  end

  test "pod_info returns :not_found when pod doesn't exist" do
    assert {:error, :not_found} = Fleet.Spawner.pod_info("nonexistent-pod-id")
  end

  test "kill_pod terminates the pod" do
    pod_id = "pod-kill-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Fleet.Spawner.spawn_pod(valid_profile(), "ticket-2", pod_id: pod_id)

    assert :ok = Fleet.Spawner.kill_pod(pod_id)
    # Mi14 : terminate_child est sync sur la mort, MAIS le cleanup Registry (via monitor) est
    # async → poll borné déterministe (≤200ms) au lieu d'un sleep fixe flaky.
    assert :ok = wait_unregistered(pod_id)
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
    # Mi14 : count_children reflète l'enfant actif dès {:ok} de start_child.
    assert Fleet.Spawner.count_pods() >= initial + 1
  end

  describe "wake_pod/1" do
    test "wake_pod :not_found for unknown pod_id" do
      assert {:error, :not_found} = Fleet.Spawner.wake_pod("never-spawned-id")
    end

    test "wake_pod :not_a_tmux_pod si le pod existe mais pas via TmuxBackend (StubBackend → tmux_session nil)" do
      pod_id = "pod-wake-stub-#{System.unique_integer([:positive])}"
      {:ok, _pid} = Fleet.Spawner.spawn_pod(valid_profile(), "ticket-wake", pod_id: pod_id)

      # StubBackend ne pose pas tmux_session dans launched → pod_info renvoie
      # tmux_session: nil → wake_pod refuse proprement (pas de send-keys).
      assert {:error, :not_a_tmux_pod} = Fleet.Spawner.wake_pod(pod_id)

      Fleet.Spawner.kill_pod(pod_id)
    end
  end

  # Poll borné déterministe (Mi14) : attend le cleanup Registry async post-terminate_child
  # (≤200ms). Remplace un sleep fixe : réussit dès que nettoyé, échoue après le bound.
  defp wait_unregistered(pod_id, tries \\ 100) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [] ->
        :ok

      _ when tries > 0 ->
        Process.sleep(2)
        wait_unregistered(pod_id, tries - 1)

      _ ->
        :timeout
    end
  end
end
