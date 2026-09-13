defmodule Fleet.Pilot.Poller.AdmissionWaitTest do
  @moduledoc """
  Checks wait-label decisions without forge I/O: adding, clearing and retaining state.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller.Admission

  describe "wait_transition/2 — la règle, sans I/O" do
    test "rien porté, une attente voulue → on pose" do
      assert Admission.wait_transition(nil, "wait/role") == {:add, "wait/role"}
    end

    test "une attente portée, plus d'attente → on RETIRE" do
      # Exclusivity replaces a label when another is added; it cannot clear a wait
      # when nothing new is written.
      assert Admission.wait_transition("wait/role", nil) == {:remove, "wait/role"}
    end

    test "la MÊME attente déjà portée → :noop (écriture sur CHANGEMENT seulement)" do
      # An unchanged wait must not cause a write on every poll.
      assert Admission.wait_transition("wait/criterion", "wait/criterion") == :noop
    end

    test "rien porté, rien voulu → :noop" do
      assert Admission.wait_transition(nil, nil) == :noop
    end

    test "une attente CHANGE de nature → on pose la neuve, l'exclusivité retire l'ancienne" do
      assert Admission.wait_transition("wait/role", "wait/capacity") == {:add, "wait/capacity"}
    end

    test ":keep ne touche à RIEN, quel que soit ce qui est porté" do
      # A dispatch error supplies no new wait opinion.
      assert Admission.wait_transition(nil, :keep) == :noop
      assert Admission.wait_transition("wait/role", :keep) == :noop
    end
  end

  describe "la table et la règle composées — ce qu'un skip réel produit" do
    test "les cinq raisons parlantes posent leur label sur un ticket vierge" do
      for {reason, label} <- [
            {:at_capacity, "wait/capacity"},
            {:role_busy, "wait/role"},
            {:draining, "wait/draining"},
            {:criterion_unavailable, "wait/criterion"},
            {:ci_pending, "wait/ci"}
          ] do
        assert Admission.wait_transition(nil, Fleet.Labels.wait_for(reason)) == {:add, label}
      end
    end

    test "une raison SILENCIEUSE sur un ticket vierge n'écrit rien" do
      for reason <- [:onboarded, :no_role, :not_fleet_branch, :in_flight, :awaits_arch, :draft] do
        assert Admission.wait_transition(nil, Fleet.Labels.wait_for(reason)) == :noop,
               "#{inspect(reason)} ne doit produire aucune écriture"
      end
    end

    test "une raison silencieuse RETIRE une attente précédente — elle ne la laisse pas pourrir" do
      # A silent skip can still require removal of an older wait label.
      assert Admission.wait_transition("wait/role", Fleet.Labels.wait_for(:onboarded)) ==
               {:remove, "wait/role"}
    end
  end
end
