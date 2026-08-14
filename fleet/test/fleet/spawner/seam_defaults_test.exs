defmodule Fleet.Spawner.SeamDefaultsTest do
  @moduledoc """
  The DEFAULT of a runtime seam is a safety property, and two of the three were held by nobody.

  Measured 2026-08-08, each mutation against the whole suite:

  | seam | default changed to | suite |
  |---|---|---|
  | `CoordBackend` | the real `Fleet.Coord` | **2435 green** |
  | `MCPSocketProvisioner` | `nil` | **2435 green** |
  | `LaunchBackend` | the test stub | 1 failure (held) |

  What the first one costs is the point. `Fleet.API.Readiness` reports `coord.backend` as
  **degraded** precisely by comparing the resolved module to `NotWiredYet` — and that comparison is
  tested. But the FALLBACK it depends on is not: flip the default to a real backend and an unwired
  fleet reports `operational` while every escalation goes nowhere. The probe would not lie about
  what it measured; it would measure something that had quietly stopped being true.

  A default is exactly the value nobody configures, so it is exactly the value no test exercises
  unless one is written for it.
  """
  use ExUnit.Case, async: true

  test "CoordBackend: unconfigured resolves to NotWiredYet — an unwired relay must READ unwired" do
    # No config gymnastics: `config/test.exs` deliberately pins nothing here, so the ambient value
    # IS the default. If someone starts pinning it, this assertion turns red rather than silent —
    # which is the correct reaction, since the fallback would then stop being observable.
    assert Application.fetch_env(:lcars_fleet, :starfleet_coord_backend) == :error,
           "un pin de :coord_backend en :test rendrait ce defaut inobservable — a traiter, pas a contourner"

    assert Fleet.Starfleet.CoordBackend.resolved() ==
             Fleet.Starfleet.CoordBackend.NotWiredYet
  end

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
