defmodule Fleet.LabelsTest do
  use ExUnit.Case, async: true

  alias Fleet.Labels

  # These values ARE the forge-state-machine wire-protocol (DN §5). A rename must be a
  # DELIBERATE, visible act (this test going red forces it) — poller/dispatcher/completer/consumer
  # agree on them to the byte. Single source F072.
  describe "protocol vocabulary (canon values)" do
    # #5.2 D4 — `dispatched` (legacy poller lock) + the `state:*` chain (state-in-label) removed;
    # only the LOCKS remain.
    test "lock labels" do
      assert Labels.in_flight() == "lcars-in-flight"
      assert Labels.awaits_arch() == "lcars-awaits-arch"
    end
  end
end
