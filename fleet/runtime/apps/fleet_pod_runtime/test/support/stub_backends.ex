defmodule Fleet.PodRuntime.StubBackends do
  @moduledoc """
  Stubs des Backend behaviours pour swap test runtime.

    * `Fleet.PodRuntime.AgentTool.SpawnerBackend` — simule spawn_pod
      + await_result selon scenarios test
  """

  defmodule AgentSuccess do
    @behaviour Fleet.PodRuntime.AgentTool.SpawnerBackend

    @impl Fleet.PodRuntime.AgentTool.SpawnerBackend
    def spawn_pod(_cap_profile, _pod_id, _opts), do: {:ok, self()}

    @impl Fleet.PodRuntime.AgentTool.SpawnerBackend
    def await_result(_pod_id, _timeout) do
      {:ok, %{output: %{"result" => "ok"}, cost_usd: 0.05}}
    end
  end

  defmodule AgentSpawnFails do
    @behaviour Fleet.PodRuntime.AgentTool.SpawnerBackend

    @impl Fleet.PodRuntime.AgentTool.SpawnerBackend
    def spawn_pod(_cap_profile, _pod_id, _opts), do: {:error, :stub_spawn_fail}

    @impl Fleet.PodRuntime.AgentTool.SpawnerBackend
    def await_result(_pod_id, _timeout), do: {:error, :unreachable}
  end

  defmodule AgentTimeout do
    @behaviour Fleet.PodRuntime.AgentTool.SpawnerBackend

    @impl Fleet.PodRuntime.AgentTool.SpawnerBackend
    def spawn_pod(_cap_profile, _pod_id, _opts), do: {:ok, self()}

    @impl Fleet.PodRuntime.AgentTool.SpawnerBackend
    def await_result(_pod_id, _timeout), do: {:error, :timeout}
  end
end
