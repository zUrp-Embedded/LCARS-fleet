defmodule Fleet.MCP.ServerTest do
  @moduledoc """
  Lot 1 inc2 — `Fleet.MCP.Server` API opaque + conformance ADR-C
  (DN D7-bis : JAMAIS démarré côté pod). Instances **nommées uniques**
  par test (test-seam `:name`) → aucun couplage au singleton umbrella
  (elixir-thinking : fix the global coupling). `async: false` (Fleet.PubSub
  partagé umbrella).
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.Server

  defp uniq, do: :"srv_#{System.unique_integer([:positive])}"

  test "conformance ADR-C : start_link refusé côté pod (boot_environment :pod)" do
    name = uniq()
    assert {:error, :forbidden_in_pod} = Server.start_link(boot_environment: :pod, name: name)
    # Ce nom unique n'a jamais été enregistré → la garde a bien court-circuité
    # AVANT tout démarrage de process (conformance prouvée sans couplage global).
    assert Process.whereis(name) == nil
  end

  test "start_link démarre côté host (défaut) sous nom isolé" do
    name = uniq()
    assert {:ok, pid} = Server.start_link(name: name)
    assert is_pid(pid) and Process.alive?(pid)
    Server.stop(name)
  end

  test "boot_environment/1 : opts > app env > défaut :host" do
    assert Server.boot_environment([]) == :host
    assert Server.boot_environment(boot_environment: :pod) == :pod

    Application.put_env(:fleet_mcp, :boot_environment, :ci)
    on_exit(fn -> Application.delete_env(:fleet_mcp, :boot_environment) end)
    assert Server.boot_environment([]) == :ci
    assert Server.boot_environment(boot_environment: :host) == :host
  end

  test "register_channel + list_channels (registre, pas hot-path broadcast)" do
    name = uniq()
    {:ok, _} = Server.start_link(name: name)
    assert Server.list_channels(name) == []
    assert :ok = Server.register_channel(name, "fleet-control", transport: ["stdio"])
    assert :ok = Server.register_channel(name, "fleet-forge", transport: ["http_sse"])
    assert Server.list_channels(name) == ["fleet-control", "fleet-forge"]
    Server.stop(name)
  end

  test "stop/1 idempotent (no-op si déjà arrêté)" do
    name = uniq()
    assert :ok = Server.stop(name)
    {:ok, _} = Server.start_link(name: name)
    assert :ok = Server.stop(name)
    assert :ok = Server.stop(name)
  end
end
