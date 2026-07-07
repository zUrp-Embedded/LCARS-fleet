defmodule Fleet.Pilot.StepDispatcherSpawnAsRoleTest do
  @moduledoc """
  Attribution du stopwatch (QoL 2026-07-07, observation user « c'est lcars-system qui est
  comptabilisé, pas le worker ») : `Spawn.spawn_step` doit démarrer le stopwatch AU NOM DU RÔLE
  dispatché (`as_role`), pas du compte système — sinon Gitea attribue tout le temps tracké à
  `lcars-system`, jamais au worker réel. Le label reste système (protocole), seul le stopwatch
  (données attribuables) est signé rôle. async: false (mute la config globale `:role_tokens_dir`).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher
  alias Fleet.Pilot.StubTaskQueue
  alias Fleet.Pilot.TestEnv

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "engineer.gitea_token"), "ENG-TOKEN")
    TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, tmp)
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
           metadata: %{"slot_scope" => "project"},
           spec: %{}
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

  test "spawn_step (dispatch_issue) : start_stopwatch signé AU NOM DE L'ENGINEER, pas du système" do
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

    # Le label reste système (protocole d'état, doctrine établie) : token INCHANGÉ.
    assert_received {:add_label, "lcars-in-flight"}

    # Le stopwatch, lui, est signé rôle : le token système est ÉCRASÉ par le token engineer.
    assert_received {:start_stopwatch, "lordzurp/lcars-test", 42, sw_opts}
    assert sw_opts[:token] == "ENG-TOKEN"
  end
end
