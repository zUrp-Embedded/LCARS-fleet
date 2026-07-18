defmodule Fleet.MCP.ServerTest do
  @moduledoc """
  `Fleet.MCP.Server` = ADR-C boot guard (DN D7-bis: NEVER started pod-side).
  **Uniquely named** instances per test (test-seam `:name`) → no coupling to the
  umbrella singleton (elixir-thinking: fix the global coupling). `async: false`
  (shared umbrella Fleet.PubSub).

  The husk API `register_channel`/`list_channels`/`stop` was removed (F049 —
  dead push channel, 0 prod callers); only the containment guard +
  `boot_environment/1` remain.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.Server

  defp uniq, do: :"srv_#{System.unique_integer([:positive])}"

  test "ADR-C conformance: start_link refused pod-side (boot_environment :pod)" do
    name = uniq()
    assert {:error, :forbidden_in_pod} = Server.start_link(boot_environment: :pod, name: name)
    # This unique name was never registered → the guard did short-circuit
    # BEFORE any process start (conformance proven without global coupling).
    assert Process.whereis(name) == nil
  end

  test "start_link starts host-side (default) under an isolated name" do
    name = uniq()
    assert {:ok, pid} = Server.start_link(name: name)
    assert is_pid(pid) and Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "boot_environment/1: opts > app env > default" do
    assert Server.boot_environment(boot_environment: :pod) == :pod

    Fleet.MCP.TestEnv.put_env_restoring(:fleet_mcp, :boot_environment, :ci)
    assert Server.boot_environment([]) == :ci
    assert Server.boot_environment(boot_environment: :host) == :host
  end

  test "boot_environment/1: FAIL-CLOSED default :pod (neither opts nor app env → refuses, never permissive :host)" do
    # Soft-fallback #6: the default used to be `:host` (permissive) — a boot that does NOT inject `:pod`
    # (config drift) started the system MCP server. Fail-closed: the ABSENCE of declaration → `:pod`
    # (refuses). The host declares itself POSITIVELY (runtime.exs on the daemon, config/test.exs in test);
    # a boot that does not is refused, never started by omission.
    saved = Application.fetch_env(:fleet_mcp, :boot_environment)
    Application.delete_env(:fleet_mcp, :boot_environment)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:fleet_mcp, :boot_environment, v)
        :error -> Application.delete_env(:fleet_mcp, :boot_environment)
      end
    end)

    assert Server.boot_environment([]) == :pod
    assert {:error, :forbidden_in_pod} = Server.start_link(name: uniq())
  end
end
