defmodule Fleet.PodRuntime.StubBackends do
  @moduledoc """
  Stubs des Backend behaviours pour swap test runtime.

    * `Fleet.PodRuntime.SDKPortBackend` — capture writes, simule erreurs
    * `Fleet.PodRuntime.AgentTool.SpawnerBackend` — simule spawn_pod
      + await_result selon scenarios test
  """

  defmodule PortCapture do
    @moduledoc """
    Backend Port stub : capture chaque `write/2` en envoyant un message
    `{:port_write, payload}` au pid enregistré dans
    `Application.get_env(:fleet_pod_runtime, :port_capture_target)`
    (default `self()` côté backend, fallback no-op si manquant).

    Le test setup doit faire `Application.put_env(:fleet_pod_runtime,
    :port_capture_target, self())` pour recevoir les writes.
    """

    @behaviour Fleet.PodRuntime.SDKPortBackend

    @impl Fleet.PodRuntime.SDKPortBackend
    def write(_port_ref, payload) do
      case Application.get_env(:fleet_pod_runtime, :port_capture_target) do
        pid when is_pid(pid) -> send(pid, {:port_write, IO.iodata_to_binary(payload)})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule PortFailing do
    @behaviour Fleet.PodRuntime.SDKPortBackend

    @impl Fleet.PodRuntime.SDKPortBackend
    def write(_port_ref, _payload), do: {:error, :stub_port_fail}
  end

  defmodule PortFlakyAfterN do
    @moduledoc """
    Backend Port stub : succès pour les `N` premiers appels, échec
    après. `N` configuré via `Application.put_env(:fleet_pod_runtime,
    :flaky_n, n)` ; compteur via `:flaky_count` (atomic via Agent).
    """

    @behaviour Fleet.PodRuntime.SDKPortBackend

    @impl Fleet.PodRuntime.SDKPortBackend
    def write(_port_ref, payload) do
      n = Application.get_env(:fleet_pod_runtime, :flaky_n, 1)
      counter_pid = Application.fetch_env!(:fleet_pod_runtime, :flaky_counter_pid)
      count = Agent.get_and_update(counter_pid, fn c -> {c, c + 1} end)

      case Application.get_env(:fleet_pod_runtime, :port_capture_target) do
        pid when is_pid(pid) -> send(pid, {:port_write, IO.iodata_to_binary(payload)})
        _ -> :ok
      end

      if count < n, do: :ok, else: {:error, :flaky_after_n}
    end
  end

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
