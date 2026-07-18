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

  test "reviewer_roles: config data, overridden by the opt" do
    assert ["qualifier", "reviewer"] == Roles.reviewer_roles()
    assert ["x"] == Roles.reviewer_roles(reviewer_roles: ["x"])
  end

  test "GatekeeperSeal.gatekeeper_role/0 re-exports the authority (same value)" do
    assert Fleet.Pilot.GatekeeperSeal.gatekeeper_role() == Roles.gatekeeper_role()
  end

  test "architect_pod_id: default `permanent-architect`, overridden by the opt (SSOT)" do
    assert "permanent-architect" == Roles.architect_pod_id()
    assert "permanent-arch2" == Roles.architect_pod_id(architect_pod_id: "permanent-arch2")
  end
end
