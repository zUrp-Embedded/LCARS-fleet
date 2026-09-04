defmodule Fleet.Admiral.ApplicationBootKnobTest do
  @moduledoc """
  F-C097 — the `:start_*` boot knobs of `Fleet.Admiral.Application` govern the supervision tree.
  Read as `if Application.get_env(...)` (truthiness), a malformed value would change the topology
  SILENTLY: a `"false"` string or `0` is TRUTHY → the child would start anyway; a stray `nil` is
  falsy → the child would be skipped even when its default is `true`. The `boot_enabled?/2` lock
  PARSES at the edge: boolean honored, absence → default, non-boolean → raise at boot (fail-closed).
  async: false (global config).
  """
  use ExUnit.Case, async: false

  alias Fleet.Admiral.Application, as: App
  alias Fleet.TestEnv

  test "explicit boolean value is honored" do
    TestEnv.put_env_restoring(:lcars_fleet, :admiral_start_mcp_monitor, false)
    refute App.boot_enabled?(:admiral_start_mcp_monitor, true)

    # Une clef ARBITRAIRE, pas un second knob reel : ce test porte sur `boot_enabled?`, pas sur
    # l'inventaire des enfants. L'epingler a un knob nomme l'a fait survivre au retrait de
    # MCPWatcher et casser un test qui ne parlait pas de lui.
    TestEnv.put_env_restoring(:lcars_fleet, :admiral_start_some_child, true)
    assert App.boot_enabled?(:admiral_start_some_child, false)
  end

  test "absent key → boolean default (no interpretation)" do
    assert App.boot_enabled?(:start_never_set_knob, true)
    refute App.boot_enabled?(:start_never_set_knob, false)
  end

  test "NON-boolean value → raise at boot (fail-closed, no silent topology drift)" do
    for bad <- ["false", "true", 0, 1, :off, nil] do
      TestEnv.put_env_restoring(:lcars_fleet, :admiral_start_mcp_monitor, bad)

      assert_raise ArgumentError, ~r/must be a boolean/, fn ->
        App.boot_enabled?(:admiral_start_mcp_monitor, true)
      end
    end
  end
end
