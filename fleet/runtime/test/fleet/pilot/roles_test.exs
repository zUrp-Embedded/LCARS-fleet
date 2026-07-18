defmodule Fleet.Pilot.RolesTest do
  @moduledoc """
  Locks the single AUTHORITY for workshop roles (`Fleet.Pilot.Roles`): canonical defaults +
  opts overrides. `ProjectOnboard` and `GatekeeperSeal` delegate here (no default rewritten elsewhere).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Roles

  test "producer_role: config default `engineer`, overridden by the opt" do
    assert "engineer" == Roles.producer_role()
    assert "designer" == Roles.producer_role(producer_role: "designer")
  end

  test "gatekeeper_role: config default `gatekeeper`, overridden by the opt" do
    assert "gatekeeper" == Roles.gatekeeper_role()
    assert "sentinel" == Roles.gatekeeper_role(gatekeeper_role: "sentinel")
  end

  test "jury: THE CARD is the source (default delegation card without a map in hand), opt = test seam" do
    # nil map → the delegation default card (brief-gate) is loaded and ITS jury returned.
    assert ["qualifier", "reviewer"] == Roles.jury(nil)
    # a loaded map in hand → its own jury, no card load.
    assert ["a", "b"] == Roles.jury(%{"jury" => ["a", "b"]})
    # injection seam (tests/hermetic overrides) — never a config.
    assert ["x"] == Roles.jury(nil, reviewer_roles: ["x"])
  end

  test "delegation_workflow_map: single accessor of the default card name" do
    assert "brief-gate" == Roles.delegation_workflow_map()
    assert "other" == Roles.delegation_workflow_map(delegation_workflow_map: "other")
  end

  test "GatekeeperSeal.gatekeeper_role/0 re-exports the authority (same value)" do
    assert Fleet.Pilot.GatekeeperSeal.gatekeeper_role() == Roles.gatekeeper_role()
  end

  test "architect_pod_id: default `permanent-architect`, overridden by the opt (SSOT)" do
    assert "permanent-architect" == Roles.architect_pod_id()
    assert "permanent-arch2" == Roles.architect_pod_id(architect_pod_id: "permanent-arch2")
  end
end
