defmodule Fleet.Pilot.Poller.AdmissionWaitTest do
  @moduledoc """
  BL-6-48, pas 3 (moitié ISSUES) — la règle PURE du label d'attente.

  Les 63 sites qui produisent un `{:skipped, reason}` sont consommés à deux endroits, et les deux
  jetaient la raison. Un ticket en file était donc indiscernable d'un ticket oublié. Ce qui est
  épinglé ici n'est pas l'écriture forge mais la DÉCISION : quand écrire, quand retirer, et surtout
  quand ne rien faire.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller.Admission

  describe "wait_transition/2 — la règle, sans I/O" do
    test "rien porté, une attente voulue → on pose" do
      assert Admission.wait_transition(nil, "wait/role") == {:add, "wait/role"}
    end

    test "une attente portée, plus d'attente → on RETIRE" do
      # Le cas que l'exclusivité native ne couvre PAS : elle agit quand on POSE un autre label du
      # scope, et un ticket qui cesse d'attendre ne pose rien. L'oublier fabriquerait l'état périmé
      # que BL-6-48 existe pour tuer — on aurait troqué une famille de défaut contre une autre.
      assert Admission.wait_transition("wait/role", nil) == {:remove, "wait/role"}
    end

    test "la MÊME attente déjà portée → :noop (écriture sur CHANGEMENT seulement)" do
      # Sans cette clause, un `criterion_unavailable` intermittent ferait battre le label toutes les
      # 30 s dans le fil de l'issue : on aurait échangé une attente invisible contre du bruit
      # permanent.
      assert Admission.wait_transition("wait/criterion", "wait/criterion") == :noop
    end

    test "rien porté, rien voulu → :noop" do
      assert Admission.wait_transition(nil, nil) == :noop
    end

    test "une attente CHANGE de nature → on pose la neuve, l'exclusivité retire l'ancienne" do
      assert Admission.wait_transition("wait/role", "wait/capacity") == {:add, "wait/capacity"}
    end

    test ":keep ne touche à RIEN, quel que soit ce qui est porté" do
      # `:keep` n'est pas un troisième label, c'est l'ABSENCE d'opinion. Une erreur de dispatch ne
      # dit rien de ce qu'un ticket attend ; écrire dessus transformerait une panne en « attente ».
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
      # Subtil et load-bearing : un ticket qui passe de `role_busy` à `onboarded` n'attend plus rien
      # de ce que le vocabulaire sait dire. Le laisser porter `wait/role` serait un état périmé.
      assert Admission.wait_transition("wait/role", Fleet.Labels.wait_for(:onboarded)) ==
               {:remove, "wait/role"}
    end
  end
end
