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

    test "stage-marker (rôle catalogue → cap-profile)" do
      assert Labels.stage_prefix() == "lcars-stage:"
      assert Labels.stage("engineer") == "lcars-stage:engineer"
      assert Labels.stage("qualifier") == "lcars-stage:qualifier"
    end
  end

  describe "parse_stage/1 (extraction du rôle depuis les labels)" do
    test "trouve le rôle du stage-marker" do
      assert Labels.parse_stage(["type:poc", "lcars-stage:engineer"]) == {:ok, "engineer"}
    end

    test "prend le PREMIER stage-marker (ticket bien formé = un seul)" do
      assert Labels.parse_stage(["lcars-stage:reviewer", "lcars-stage:qualifier"]) ==
               {:ok, "reviewer"}
    end

    test "aucun stage-marker → :error" do
      assert Labels.parse_stage(["lcars-in-flight", "state:delivered"]) == :error
      assert Labels.parse_stage([]) == :error
    end

    test "stage-marker à rôle vide (`lcars-stage:`) ignoré → :error" do
      assert Labels.parse_stage(["lcars-stage:"]) == :error
    end
  end
end
