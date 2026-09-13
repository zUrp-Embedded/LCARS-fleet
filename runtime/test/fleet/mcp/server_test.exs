defmodule Fleet.MCP.ServerTest do
  @moduledoc """
  Boot-environment guard using uniquely named processes. Serialized because tests
  modify application configuration. Default host startup relies on config/test.exs;
  only :pod is refused by start_link, as distinct from an exclusive :host allowlist.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.Server

  defp uniq, do: :"srv_#{System.unique_integer([:positive])}"

  test "ADR-C conformance: start_link refused pod-side (boot_environment :pod)" do
    name = uniq()
    assert {:error, :forbidden_in_pod} = Server.start_link(boot_environment: :pod, name: name)
    # A unique name avoids observing the application's already-running singleton.
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

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_boot_environment, :ci)
    assert Server.boot_environment([]) == :ci
    assert Server.boot_environment(boot_environment: :host) == :host
  end

  test "boot_environment/1: FAIL-CLOSED default :pod (neither opts nor app env → refuses, never permissive :host)" do
    # With both configuration sources absent, the :pod default must refuse startup.
    saved = Application.fetch_env(:lcars_fleet, :mcp_boot_environment)
    Application.delete_env(:lcars_fleet, :mcp_boot_environment)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:lcars_fleet, :mcp_boot_environment, v)
        :error -> Application.delete_env(:lcars_fleet, :mcp_boot_environment)
      end
    end)

    assert Server.boot_environment([]) == :pod
    assert {:error, :forbidden_in_pod} = Server.start_link(name: uniq())
  end
end
