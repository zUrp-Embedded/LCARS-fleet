defmodule Fleet.EventRouter.SignalsOSTest do
  use ExUnit.Case, async: true

  alias Fleet.EventRouter.SignalsOS

  test "R0-EVT-011: init/1 RAISES (fail-loud) — refuses to start an unimplemented SignalsOS" do
    # Enabling `:start_signals` must fail LOUDLY at boot rather than capture SIGTERM/SIGHUP in a
    # dead handler. The raise happens BEFORE any `:os.set_signal` (no signal captured).
    assert_raise RuntimeError, ~r/not implemented/, fn ->
      SignalsOS.init([])
    end
  end
end
