defmodule Fleet.Pilot.LabelsTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Labels

  # Ces valeurs SONT le wire-protocol forge-state-machine (DN §5). Un renommage doit être un acte
  # DÉLIBÉRÉ et visible (ce test rouge le force) — poller/dispatcher/completer/consumer s'accordent
  # dessus au byte près. Source unique F072.
  describe "vocabulaire protocole (valeurs canon)" do
    test "labels de verrou + dispatch" do
      assert Labels.in_flight() == "lcars-in-flight"
      assert Labels.awaits_human() == "lcars-awaits-human"
      assert Labels.dispatched() == "lcars-dispatched"
    end

    test "labels d'état" do
      assert Labels.state_prefix() == "state:"
      assert Labels.state("delivered") == "state:delivered"
      assert Labels.delivered() == "state:delivered"
      assert Labels.state("judged") == "state:judged"
    end
  end
end
