defmodule Fleet.MCP.SupervisorTest do
  @moduledoc """
  Z7.3 (2026-06-10) — remplace l'ex-`mcp_bridge_supervisor_test.exs` (dont ~90 %
  testait le `Fleet.MCP.Bridge` mort, retiré MCP-D1). Ne garde que le smoke
  d'intégration utile : l'umbrella a booté `Fleet.MCP.Supervisor` + son seul enfant
  permanent `Fleet.MCP.Server` (PodTools = SSI `:pod_facing_port`, absent en test).
  La conformance ADR-C `Server` refuse `:pod` est couverte par `mcp_server_test.exs`.
  """
  use ExUnit.Case, async: false

  test "Supervisor umbrella : Server vivant (boot host), plus de Bridge" do
    assert is_pid(Process.whereis(Fleet.MCP.Supervisor))
    assert is_pid(Process.whereis(Fleet.MCP.Server))
    # Bridge retiré (husk mort) — ne doit plus être dans l'arbre.
    assert Process.whereis(Fleet.MCP.Bridge) == nil
  end

  describe "pod_facing_status/0 — sonde le PROCESS, pas le knob (anti-vert-creux)" do
    # En ambient test : `:pod_facing_port` absent → le superviseur a booté SANS PodTools.
    test ":inactive quand pod_facing_port non configuré (off volontaire)" do
      # garde-fou : l'ambient ne pose pas le port
      assert is_nil(Application.get_env(:fleet_mcp, :pod_facing_port))
      assert {:inactive, detail} = Fleet.MCP.Supervisor.pod_facing_status()
      assert detail.note =~ "non configuré"
    end

    # Cas VERT-CREUX corrigé : le knob dit ON (port posé) mais le listener PodTools
    # ne tourne pas (le superviseur ambient a booté sans, le port arrive après coup).
    # La sonde doit rendre :degraded (et NON :operational sur la seule présence du knob).
    test ":degraded quand port configuré mais PodTools non vivant" do
      Application.put_env(:fleet_mcp, :pod_facing_port, 64_999)
      on_exit(fn -> Application.delete_env(:fleet_mcp, :pod_facing_port) end)

      assert {:degraded, detail} = Fleet.MCP.Supervisor.pod_facing_status()
      assert detail.pod_facing_port == 64_999
      assert detail.pod_tools == false
      assert detail.note =~ "PodTools non vivant"
    end
  end
end
