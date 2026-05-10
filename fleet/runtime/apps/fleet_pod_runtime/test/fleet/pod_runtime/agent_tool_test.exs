defmodule Fleet.PodRuntime.AgentToolTest do
  use ExUnit.Case, async: false

  alias Fleet.PodRuntime.AgentTool
  alias Fleet.PodRuntime.StubBackends

  defp fire_mode_quick_profile do
    %Fleet.CapProfile{
      api_version: "lcars/v2.5",
      kind: "CapabilityProfile",
      metadata: %{"name" => "fire-mode-quick"},
      spec: %{
        "scope" => %{"allowedTools" => ["Read"], "disallowedTools" => []},
        "invocation" => %{
          "max_alive_sec" => 60,
          "cost_cap_usd" => 0.20,
          "output_format" => "json-strict"
        }
      }
    }
  end

  describe "spawn/2 — happy path via stub backend" do
    test "spawn_pod ok + await_result ok → {:ok, %{output, cost_usd, duration_ms}}" do
      assert {:ok, result} =
               AgentTool.spawn("audit module X",
                 cap_profile: fire_mode_quick_profile(),
                 pod_id: "agent-tool-pod-1",
                 timeout_ms: 100,
                 backend: StubBackends.AgentSuccess
               )

      assert %{output: %{"result" => "ok"}, cost_usd: 0.05, duration_ms: dur} = result
      assert is_integer(dur) and dur >= 0
    end
  end

  describe "spawn/2 — propagation erreurs" do
    test "spawn_pod fail → {:error, reason}" do
      assert {:error, :stub_spawn_fail} =
               AgentTool.spawn("brief",
                 cap_profile: fire_mode_quick_profile(),
                 pod_id: "agent-tool-pod-fail",
                 timeout_ms: 100,
                 backend: StubBackends.AgentSpawnFails
               )
    end

    test "await_result timeout → {:error, :timeout}" do
      assert {:error, :timeout} =
               AgentTool.spawn("brief",
                 cap_profile: fire_mode_quick_profile(),
                 pod_id: "agent-tool-pod-timeout",
                 timeout_ms: 100,
                 backend: StubBackends.AgentTimeout
               )
    end
  end

  describe "default backend (Fleet.Spawner.spawn_pod, await_result NotWiredYet)" do
    test "SpawnerBackend.Default.await_result/2 retourne {:error, :not_wired_yet}" do
      assert {:error, :not_wired_yet} =
               Fleet.PodRuntime.AgentTool.SpawnerBackend.Default.await_result("any-pod", 60_000)
    end
  end
end
