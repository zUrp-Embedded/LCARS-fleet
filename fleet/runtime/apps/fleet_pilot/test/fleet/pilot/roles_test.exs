defmodule Fleet.Pilot.RolesTest do
  @moduledoc """
  Verrouille l'AUTORITÉ unique des rôles de l'atelier (`Fleet.Pilot.Roles`) : défauts canon +
  overrides opts. `ProjectOnboard` et `GatekeeperSeal` délèguent ici (plus de défaut réécrit ailleurs).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Roles

  test "producer_role : défaut config `engineer`, override par l'opt" do
    assert "engineer" == Roles.producer_role()
    assert "designer" == Roles.producer_role(producer_role: "designer")
  end

  test "gatekeeper_role : défaut config `gatekeeper`, override par l'opt" do
    assert "gatekeeper" == Roles.gatekeeper_role()
    assert "sentinel" == Roles.gatekeeper_role(gatekeeper_role: "sentinel")
  end

  test "reviewer_roles : data config, override par l'opt" do
    assert ["qualifier", "reviewer"] == Roles.reviewer_roles()
    assert ["x"] == Roles.reviewer_roles(reviewer_roles: ["x"])
  end

  test "GatekeeperSeal.gatekeeper_role/0 re-exporte l'autorité (même valeur)" do
    assert Fleet.Pilot.GatekeeperSeal.gatekeeper_role() == Roles.gatekeeper_role()
  end
end
