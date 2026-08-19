defmodule Fleet.Pilot.StepDispatcherSpawnAsRoleTest do
  @moduledoc """
  Stopwatch attribution: `Spawn.spawn_step` must start the stopwatch IN THE NAME OF THE dispatched
  ROLE (`as_role`), not the system account — otherwise Gitea attributes all tracked time to
  `system_starfleet`, never to the real worker. The label stays system-signed (protocol), only the
  stopwatch (attributable data) is role-signed. async: false (mutates the global `:role_tokens_dir`
  config).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher
  alias Fleet.Pilot.StubTaskQueue
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
    Fleet.TestEnv.put_role_token!("engineer", "ENG-TOKEN")
    :ok
  end

  defmodule TokenCaptureForge do
    def add_label(_repo, _n, label, _opts) do
      send(self(), {:add_label, label})
      {:ok, :added}
    end

    def start_stopwatch(repo, n, opts) do
      send(self(), {:start_stopwatch, repo, n, opts})
      :ok
    end

    def stop_stopwatch(_repo, _n, _opts), do: :ok
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)
  end

  defmodule StubLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}
  end

  defmodule StubSpawner do
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  defp dispatch_opts do
    [
      repo: "lordzurp/lcars-test",
      forge_client: TokenCaptureForge,
      forge_opts: [token: "system-token", _test_route: {:ok, {"g", "build"}}],
      loader: StubLoader,
      spawner: StubSpawner,
      task_queue: StubTaskQueue,
      project_resolver: fn _repo, _opts -> {:ok, nil} end,
      workflow_map_loader: fn _name ->
        %{
          "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
          "max_rework_rounds" => 2
        }
      end
    ]
  end

  test "spawn_step (dispatch_issue): start_stopwatch signed AS THE ENGINEER, not the system" do
    payload = %{
      "issue" => %{
        "number" => 42,
        "body" => "fais le hello",
        "labels" => [],
        "assignees" => [%{"login" => "lordzurp"}]
      }
    }

    assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
             StepDispatcher.dispatch_issue(payload, dispatch_opts())

    # The label stays system-signed (state protocol, established doctrine): token UNCHANGED.
    assert_received {:add_label, "lcars-in-flight"}

    # The stopwatch, however, is role-signed: the system token is OVERWRITTEN by the engineer token.
    assert_received {:start_stopwatch, "lordzurp/lcars-test", 42, sw_opts}
    assert sw_opts[:token] == "ENG-TOKEN"
  end
end
