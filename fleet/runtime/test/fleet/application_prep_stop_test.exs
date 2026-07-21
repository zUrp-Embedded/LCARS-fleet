defmodule Fleet.ApplicationPrepStopTest do
  @moduledoc """
  The nominal stop's graceful door: SIGTERM → :init.stop → prep_stop, which drains
  through Shutdown.begin BEFORE any supervisor dies. An absent server (hermetic boots)
  or a failing drain must never wedge the teardown — prep_stop always passes the state
  through.
  """
  # async: false — registers the REAL Fleet.Starfleet.Shutdown global name.
  use ExUnit.Case, async: false

  test "with the Shutdown server up, prep_stop drains and passes the state through" do
    # Real server under its global name (prep_stop resolves it by Process.whereis),
    # NoOp dispatcher default, fast poll — the drain concludes immediately (0 in-flight).
    start_supervised!({Fleet.Starfleet.Shutdown, name: Fleet.Starfleet.Shutdown, poll_ms: 10})

    assert Fleet.Application.prep_stop(:app_state) == :app_state
  end

  test "without the server (hermetic boot), prep_stop passes through untouched" do
    refute Process.whereis(Fleet.Starfleet.Shutdown)
    assert Fleet.Application.prep_stop(:app_state) == :app_state
  end
end
