defmodule Fleet.ApplicationPrepStopTest do
  @moduledoc """
  Calls prep_stop directly with absent or NoOp Shutdown. Checks state passthrough;
  does not send SIGTERM, fail the drain or assert its invocation/order against teardown.
  """
  # async: false — registers the REAL Fleet.Admiral.Shutdown global name.
  use ExUnit.Case, async: false

  test "with the Shutdown server up, prep_stop drains and passes the state through" do
    # Real named server with NoOp counting and short polls; no actual work drains.
    start_supervised!({Fleet.Admiral.Shutdown, name: Fleet.Admiral.Shutdown, poll_ms: 10})

    assert Fleet.Application.prep_stop(:app_state) == :app_state
  end

  test "without the server (hermetic boot), prep_stop passes through untouched" do
    refute Process.whereis(Fleet.Admiral.Shutdown)
    assert Fleet.Application.prep_stop(:app_state) == :app_state
  end
end
