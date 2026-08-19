defmodule Fleet.Spawner.SeamDefaultsTest do
  @moduledoc """
  The DEFAULT of a runtime seam is a safety property, and two of the three were held by nobody.

  Measured 2026-08-08, each mutation against the whole suite:

  | seam | default changed to | suite |
  |---|---|---|
  | `MCPSocketProvisioner` | `nil` | **2435 green** |
  | `LaunchBackend` | the test stub | 1 failure (held) |

  What the first one costs is the point. ⚠ `Fleet.API.Readiness` — qui rapportait `coord.backend`
  **degrade** en comparant le module resolu a `NotWiredYet` — A ETE SUPPRIMEE le 2026-08-14 avec la
  surface TCP qu'elle servait : elle calculait un verdict que PERSONNE ne lisait (son unique
  appelant etait l'endpoint `/api/readiness/deep`, lui-meme sans client). Une sonde dont personne ne
  lit la sortie n'est pas un garde, c'est un commentaire qui coute un calcul.

  CE QUI RESTE VRAI, ET C'EST TOUT LE SUJET DE CE FICHIER : le FALLBACK dont ce verdict dependait
  n'est, lui, toujours pas teste ailleurs. Flip the default to a real backend and an unwired
  fleet reports `operational` while every escalation goes nowhere. The probe would not lie about
  what it measured; it would measure something that had quietly stopped being true.

  A default is exactly the value nobody configures, so it is exactly the value no test exercises
  unless one is written for it.
  """
  use ExUnit.Case, async: true


  test "MCPSocketProvisioner: the canonical default is the real fleet_mcp side" do
    # Asserted on `default/0` rather than through `resolved/0`: reaching the fallback would mean
    # deleting the key globally, and an async suite would then hand the REAL provisioner to
    # whatever pod test is mid-flight. A hazard bought to test a constant is a bad trade.
    assert Fleet.Spawner.McpSocketProvisioner.default() == Fleet.MCP.PodSocketSupervisor
  end

  test "MCPSocketProvisioner: a configured provisioner still WINS over the default" do
    # The other half of the contract. Without it, `resolved/0` could return the default
    # unconditionally and the test above would still pass — the seam would be sealed shut.
    assert Fleet.Spawner.McpSocketProvisioner.resolved() == Fleet.Spawner.MCPSocketStub

    refute Fleet.Spawner.McpSocketProvisioner.resolved() ==
             Fleet.Spawner.McpSocketProvisioner.default()
  end
end
