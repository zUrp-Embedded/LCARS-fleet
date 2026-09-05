defmodule Fleet.Pilot.ForgeFinchTest do
  @moduledoc """
  Dedicated HTTP pool `Fleet.Forge.Finch` — the ForgeClient's anti-stale wiring.

  We PROBE the real process (anti-hollow-green), not a config knob: if the pool is removed from the
  `Fleet.Pilot.Application` tree, this test breaks. The BEHAVIOR (`conn_max_idle_time` closes a
  connection idle >30s before the forge closes it server-side → no more hung-first-call) is
  temporal/network-bound and cannot be isolated in a unit test; its proof lives in the ForgeClient
  instrumentation on a real run (slow-call log).
  """
  use ExUnit.Case, async: true

  test "the dedicated forge pool runs in the tree (started unconditionally by the Application)" do
    assert is_pid(Process.whereis(Fleet.Forge.Finch))
  end
end
