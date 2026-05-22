defmodule Fleet.Spawner.PodTest do
  use ExUnit.Case, async: false

  alias Fleet.Spawner.LaunchBackend.StubBackend

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Override config knobs to use tmp_dir
    Application.put_env(:fleet_spawner, :state_fs_root, Path.join(tmp_dir, "state"))
    Application.put_env(:fleet_spawner, :pod_dir_root, Path.join(tmp_dir, "pods"))
    Application.put_env(:fleet_spawner, :launch_backend, StubBackend)

    # Override fleet_credentials creds_root for resolve_env
    coffre = Path.join(tmp_dir, "coffre")
    Application.put_env(:fleet_credentials, :creds_root, coffre)
    File.mkdir_p!(Path.join(coffre, "engineer"))
    File.write!(Path.join([coffre, "engineer", "oauth_refresh_token"]), "rt-stub")
    File.write!(Path.join([coffre, "engineer", "oauth_access_token"]), "at-stub")

    File.write!(
      Path.join([coffre, "engineer", "oauth_scopes"]),
      "user:inference user:sessions:claude_code"
    )

    # Override fleet_spbuilder roots (cap profile points to engineer-role.md)
    sp_root = Path.join(tmp_dir, "cap-profiles")
    File.mkdir_p!(sp_root)
    File.write!(Path.join(sp_root, "engineer-role.md"), "# Engineer SP base")
    Application.put_env(:fleet_spbuilder, :sp_role_root, sp_root)

    on_exit(fn ->
      StubBackend.clear()
      Application.delete_env(:fleet_spawner, :state_fs_root)
      Application.delete_env(:fleet_spawner, :pod_dir_root)
      # B5 #576 : baseline hermétique config/test.exs StubBackend
      # conservée (cf. spawner_test.exs même raison).
      Application.delete_env(:fleet_credentials, :creds_root)
      Application.delete_env(:fleet_spbuilder, :sp_role_root)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp valid_profile do
    %Fleet.CapProfile{
      api_version: "lcars/v2.5",
      kind: "CapabilityProfile",
      metadata: %{"name" => "engineer", "containment" => "bwrap"},
      spec: %{
        "lifetime_scope" => "one-shot",
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

  defp spawn_via_supervisor(args) do
    # Direct start_link bypassing the application supervisor for unit isolation
    pid = self()
    StubBackend.set_parent(pid)
    Fleet.Spawner.Pod.start_link(args)
  end

  defp build_args(pod_id, ticket_id) do
    %{cap_profile: valid_profile(), ticket_id: ticket_id, pod_id: pod_id, opts: []}
  end

  setup do
    # Ensure registry is up (test-mode app may already have started it)
    case Registry.start_link(keys: :unique, name: Fleet.Spawner.Registry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  describe "happy path 8 phases" do
    test "spawn_pod runs all phases when launch backend returns success" do
      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/stub.ndjson",
           session_id: "stub-1"
         }}
      )

      pod_id = "pod-happy-#{System.unique_integer([:positive])}"
      assert {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

      # Wait for the chain to complete
      assert_receive {:launch_called, _args, env}, 2_000
      assert env["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] == "rt-stub"

      Process.sleep(50)
      info = GenServer.call(pid, :info)
      assert info.phase == :succeeded
      assert :init_validated in info.conditions
      assert :home_projected in info.conditions
      assert :context_injected in info.conditions
    end

    test "POD_DIR is created under pod_dir_root" do
      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/stub.ndjson"
         }}
      )

      pod_id = "pod-dir-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))
      assert_receive {:launch_called, _args, _env}, 2_000

      info = GenServer.call(pid, :info)
      assert File.dir?(info.pod_dir)
      assert File.exists?(Path.join(info.pod_dir, ".cap-profile.json"))
      assert File.exists?(Path.join(info.pod_dir, ".claude/system-prompt.md"))
      assert File.exists?(Path.join(info.pod_dir, ".claude/CLAUDE.md"))
      assert File.exists?(Path.join(info.pod_dir, "context/brief.md"))
    end

    test "state.json is written after launch (recovery point)" do
      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/stub.ndjson"
         }}
      )

      pod_id = "pod-state-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))
      assert_receive {:launch_called, _args, _env}, 2_000
      Process.sleep(50)

      info = GenServer.call(pid, :info)
      assert File.exists?(info.state_fs_path), "state.json absent at #{info.state_fs_path}"
      content = File.read!(info.state_fs_path) |> Jason.decode!()
      assert content["pod_id"] == pod_id
      assert content["ticket_id"] == "ticket-1"
      assert content["v"] == 1
      assert is_binary(content["session_id"])
    end
  end

  describe "F-INIT-VALIDATE rejection" do
    test "init message missing fields → phase :failed" do
      Process.flag(:trap_exit, true)
      bad_init = StubBackend.valid_init_message() |> Map.delete("tools")
      StubBackend.set_reply({:ok, %{init_message: bad_init, ndjson_log: "/tmp/x.ndjson"}})

      pod_id = "pod-bad-init-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

      assert_receive {:EXIT, ^pid, {:shutdown, {:init_validation_failed, _}}}, 2_000
    end

    test "api_key_source != oauth → phase :failed" do
      Process.flag(:trap_exit, true)

      bad_init = StubBackend.valid_init_message() |> Map.put("api_key_source", "anthropic")

      StubBackend.set_reply({:ok, %{init_message: bad_init, ndjson_log: "/tmp/x.ndjson"}})

      pod_id = "pod-bad-key-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

      assert_receive {:EXIT, ^pid,
                      {:shutdown,
                       {:init_validation_failed, {:api_key_source_invalid, "anthropic"}}}},
                     2_000
    end
  end

  describe "launch backend errors" do
    test "backend :error → phase :failed with reason" do
      Process.flag(:trap_exit, true)
      StubBackend.set_reply({:error, :bwrap_failed})

      pod_id = "pod-launch-fail-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

      assert_receive {:EXIT, ^pid, {:shutdown, {:launch_failed, :bwrap_failed}}}, 2_000
    end
  end

  describe "credentials missing" do
    test "coffre missing → phase :failed" do
      Process.flag(:trap_exit, true)
      File.rm_rf!(Application.get_env(:fleet_credentials, :creds_root))
      StubBackend.set_reply({:ok, %{init_message: %{}, ndjson_log: "/tmp/x.ndjson"}})

      pod_id = "pod-no-creds-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))

      assert_receive {:EXIT, ^pid, {:shutdown, {:credentials_resolve_failed, _}}}, 2_000
    end
  end

  # ============================================================
  # #593 D11 — handle_info Port lifecycle (post-init NDJSON events)
  # ============================================================
  #
  # Avant D11 : Port messages post-init tombaient dans le catch-all default
  # GenServer → log unexpected message, state machine ne notait jamais la
  # complétion. Fix : handle_info clauses {:data, chunk} (parse NDJSON +
  # broadcast pod.completed/failed) et {:exit_status, code} (broadcast
  # pod.terminated + stop normal).
  describe "#593 D11 — Port stream lifecycle" do
    setup do
      # Fake port réel (sleep, ne sort rien, port reste owned tant que
      # process alive). Cleanup on_exit.
      fake_port = Port.open({:spawn, "/bin/sleep 60"}, [:binary, :exit_status])

      on_exit(fn ->
        if is_port(fake_port) and Port.info(fake_port) != nil, do: Port.close(fake_port)
      end)

      {:ok, fake_port: fake_port}
    end

    test "port stored in state after launch (when backend returns port)", %{
      fake_port: fake_port
    } do
      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/x.ndjson",
           port: fake_port
         }}
      )

      pod_id = "pod-port-stored-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-port"))
      assert_receive {:launch_called, _, _}, 2_000
      Process.sleep(50)

      info = GenServer.call(pid, :info)
      assert info.phase == :succeeded
      assert info.last_result == nil
    end

    test "result event is_error=false → state.last_result populated", %{fake_port: fake_port} do
      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/x.ndjson",
           port: fake_port
         }}
      )

      pod_id = "pod-result-ok-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-result"))
      assert_receive {:launch_called, _, _}, 2_000
      Process.sleep(50)

      # Stream result event via fake port (D11 handle_info clause matches
      # on %{port: fake_port}).
      chunk =
        "{\"type\":\"result\",\"is_error\":false,\"duration_ms\":1234,\"result\":\"done\"}\n"

      send(pid, {fake_port, {:data, chunk}})
      Process.sleep(20)

      info = GenServer.call(pid, :info)

      assert info.last_result == %{
               "type" => "result",
               "is_error" => false,
               "duration_ms" => 1234,
               "result" => "done"
             }
    end

    test "result event is_error=true → state.last_result populated (failed)", %{
      fake_port: fake_port
    } do
      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/x.ndjson",
           port: fake_port
         }}
      )

      pod_id = "pod-result-fail-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-fail"))
      assert_receive {:launch_called, _, _}, 2_000
      Process.sleep(50)

      chunk = "{\"type\":\"result\",\"is_error\":true,\"error\":\"budget_exceeded\"}\n"
      send(pid, {fake_port, {:data, chunk}})
      Process.sleep(20)

      info = GenServer.call(pid, :info)
      assert info.last_result["is_error"] == true
    end

    test "chunks fragmentés sur ligne (partial event) → buffer accumule", %{
      fake_port: fake_port
    } do
      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/x.ndjson",
           port: fake_port
         }}
      )

      pod_id = "pod-chunked-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-chunk"))
      assert_receive {:launch_called, _, _}, 2_000
      Process.sleep(50)

      # Split arbitraire d'un result event en 3 chunks
      send(pid, {fake_port, {:data, "{\"type\":\"result\",\"is_error"}})
      send(pid, {fake_port, {:data, "\":false,\"duration_ms\":99"}})
      send(pid, {fake_port, {:data, "}\n"}})
      Process.sleep(30)

      info = GenServer.call(pid, :info)
      assert info.last_result["type"] == "result"
      assert info.last_result["is_error"] == false
      assert info.last_result["duration_ms"] == 99
    end

    test "exit_status → process stops normal", %{fake_port: fake_port} do
      Process.flag(:trap_exit, true)

      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/x.ndjson",
           port: fake_port
         }}
      )

      pod_id = "pod-exit-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-exit"))
      assert_receive {:launch_called, _, _}, 2_000
      Process.sleep(50)

      send(pid, {fake_port, {:exit_status, 0}})

      # Pod GenServer transitionne {:stop, :normal, _} → notification :EXIT.
      assert_receive {:EXIT, ^pid, :normal}, 1_000
    end

    test "garbage JSON in chunk → ignored silently (no crash)", %{fake_port: fake_port} do
      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/x.ndjson",
           port: fake_port
         }}
      )

      pod_id = "pod-garbage-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-garb"))
      assert_receive {:launch_called, _, _}, 2_000
      Process.sleep(50)

      send(pid, {fake_port, {:data, "not-json-at-all\n{\"valid\":true}\n"}})
      Process.sleep(20)

      info = GenServer.call(pid, :info)
      # Pas de crash, last_result reste nil (la ligne valide n'est pas un
      # type:result donc handle_event/2 catch-all → no-op).
      assert info.last_result == nil
    end

    test "messages avec port différent → ignorés (catch-all)", %{fake_port: fake_port} do
      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/x.ndjson",
           port: fake_port
         }}
      )

      pod_id = "pod-other-port-#{System.unique_integer([:positive])}"
      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "t-other"))
      assert_receive {:launch_called, _, _}, 2_000
      Process.sleep(50)

      other_port = Port.open({:spawn, "/bin/sleep 60"}, [:binary, :exit_status])
      send(pid, {other_port, {:data, "{\"type\":\"result\",\"is_error\":false}\n"}})
      Process.sleep(20)

      # Le matching %{port: fake_port} échoue → catch-all → no-op.
      info = GenServer.call(pid, :info)
      assert info.last_result == nil

      Port.close(other_port)
    end
  end

  describe "Recovery from state FS" do
    test "init/1 reads state.json and skips to :launching when session_id present" do
      pod_id = "pod-recover-#{System.unique_integer([:positive])}"

      # Pre-write a state.json simulating a prior run
      state_root = Application.get_env(:fleet_spawner, :state_fs_root)
      state_path = Path.join([state_root, "pods", pod_id, "state.json"])
      File.mkdir_p!(Path.dirname(state_path))

      File.write!(
        state_path,
        Jason.encode!(%{
          "v" => 1,
          "pod_id" => pod_id,
          "ticket_id" => "ticket-old",
          "session_id" => "session-old",
          "phase" => "launching"
        })
      )

      StubBackend.set_reply(
        {:ok,
         %{
           init_message: StubBackend.valid_init_message(),
           ndjson_log: "/tmp/recover.ndjson",
           session_id: "session-old"
         }}
      )

      {:ok, pid} = spawn_via_supervisor(build_args(pod_id, "ticket-1"))
      assert_receive {:launch_called, args, _env}, 2_000
      assert args.session_id == "session-old"

      Process.sleep(50)
      info = GenServer.call(pid, :info)
      assert info.phase == :succeeded
    end
  end
end
