defmodule Fleet.Admiral.ApplicationBootKnobTest do
  @moduledoc """
  Checks strict boolean boot settings: absent uses the default, nonboolean raises.
  Elixir truthiness would accept strings such as false. No child tree starts here.
  """
  use ExUnit.Case, async: false

  alias Fleet.Admiral.Application, as: App
  alias Fleet.TestEnv

  test "explicit boolean value is honored" do
    TestEnv.put_env_restoring(:lcars_fleet, :admiral_start_mcp_monitor, false)
    refute App.boot_enabled?(:admiral_start_mcp_monitor, true)

    # Use an arbitrary key: this tests the helper, not the evolving child inventory.
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
