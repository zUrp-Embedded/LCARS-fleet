defmodule Fleet.MCP.SupervisorTest do
  @moduledoc """
  Smoke d'intégration du superviseur racine `fleet_mcp` : l'umbrella a booté
  `Fleet.MCP.Supervisor` + ses enfants permanents — `Fleet.MCP.Server` (garde de
  boot), le `Registry` `Fleet.MCP.PodSocketRegistry`, et le DynamicSupervisor
  d'accepteurs de socket `Fleet.MCP.PodSocketSupervisor` (démarré host-side
  inconditionnellement, sans aucune socket tant qu'aucun pod n'est provisionné).
  """
  use ExUnit.Case, async: false

  test "Supervisor umbrella : Server + substrat socket pod-facing vivants, plus de Bridge" do
    assert is_pid(Process.whereis(Fleet.MCP.Supervisor))
    assert is_pid(Process.whereis(Fleet.MCP.Server))
    assert is_pid(Process.whereis(Fleet.MCP.PodSocketRegistry))
    assert is_pid(Process.whereis(Fleet.MCP.PodSocketSupervisor))
    # Bridge retiré (husk mort) — ne doit plus être dans l'arbre.
    assert Process.whereis(Fleet.MCP.Bridge) == nil
  end

  describe "pod_facing_status/0 — sonde le PROCESS (le DynamicSupervisor d'accepteurs), pas un knob" do
    test ":operational quand le DynamicSupervisor d'accepteurs tourne (host-side)" do
      assert {:operational, detail} = Fleet.MCP.Supervisor.pod_facing_status()
      assert detail.acceptor_supervisor == true
      # Aucun pod provisionné dans l'ambient test → zéro accepteur/socket actif.
      assert detail.sockets == 0
    end
  end
end
