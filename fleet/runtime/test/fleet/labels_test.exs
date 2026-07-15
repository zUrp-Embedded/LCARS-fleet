defmodule Fleet.LabelsTest do
  use ExUnit.Case, async: true

  alias Fleet.Labels

  # Ces valeurs SONT le wire-protocol forge-state-machine (DN §5). Un renommage doit être un acte
  # DÉLIBÉRÉ et visible (ce test rouge le force) — poller/dispatcher/completer/consumer s'accordent
  # dessus au byte près. Source unique F072.
  describe "vocabulaire protocole (valeurs canon)" do
    # #5.2 D4 — `dispatched` (lock poller legacy) + la chaîne `state:*` (état-dans-label) retirés ;
    # ne restent que les VERROUS.
    test "labels de verrou" do
      assert Labels.in_flight() == "lcars-in-flight"
      assert Labels.awaits_arch() == "lcars-awaits-arch"
    end
  end
end
