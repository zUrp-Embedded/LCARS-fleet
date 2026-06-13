defmodule Fleet.MCP.ServerTest do
  @moduledoc """
  `Fleet.MCP.Server` = garde de boot ADR-C (DN D7-bis : JAMAIS démarré côté pod).
  Instances **nommées uniques** par test (test-seam `:name`) → aucun couplage au
  singleton umbrella (elixir-thinking : fix the global coupling). `async: false`
  (Fleet.PubSub partagé umbrella).

  L'API husk `register_channel`/`list_channels`/`stop` a été retirée (F049 — push
  channel mort chantier 7, 0 appelant prod) ; ne restent que la garde de containment
  + `boot_environment/1`.
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
    GenServer.stop(pid)
  end

  test "boot_environment/1 : opts > app env > défaut :host" do
    assert Server.boot_environment([]) == :host
    assert Server.boot_environment(boot_environment: :pod) == :pod

    Application.put_env(:fleet_mcp, :boot_environment, :ci)
    on_exit(fn -> Application.delete_env(:fleet_mcp, :boot_environment) end)
    assert Server.boot_environment([]) == :ci
    assert Server.boot_environment(boot_environment: :host) == :host
  end
end
