defmodule Fleet.Starfleet.ApplicationBootKnobTest do
  @moduledoc """
  F-C097 — the `:start_*` boot knobs of `Fleet.Starfleet.Application` govern the supervision tree.
  Read as `if Application.get_env(...)` (truthiness), a malformed value would change the topology
  SILENTLY: a `"false"` string or `0` is TRUTHY → the child would start anyway; a stray `nil` is
  falsy → the child would be skipped even when its default is `true`. The `boot_enabled?/2` lock
  PARSES at the edge: boolean honored, absence → default, non-boolean → raise at boot (fail-closed).
  async: false (global config).
  """
  use ExUnit.Case, async: false

  alias Fleet.Starfleet.Application, as: App
  alias Fleet.Starfleet.TestEnv

  test "explicit boolean value is honored" do
    TestEnv.put_env_restoring(:fleet_starfleet, :start_mcp_monitor, false)
    refute App.boot_enabled?(:start_mcp_monitor, true)

    TestEnv.put_env_restoring(:fleet_starfleet, :start_mcp_watcher, true)
    assert App.boot_enabled?(:start_mcp_watcher, false)
  end

  test "absent key → boolean default (no interpretation)" do
    assert App.boot_enabled?(:start_never_set_knob, true)
    refute App.boot_enabled?(:start_never_set_knob, false)
  end

  test "NON-boolean value → raise at boot (fail-closed, no silent topology drift)" do
    for bad <- ["false", "true", 0, 1, :off, nil] do
      TestEnv.put_env_restoring(:fleet_starfleet, :start_mcp_monitor, bad)

      assert_raise ArgumentError, ~r/must be a boolean/, fn ->
        App.boot_enabled?(:start_mcp_monitor, true)
      end
    end
  end
end
