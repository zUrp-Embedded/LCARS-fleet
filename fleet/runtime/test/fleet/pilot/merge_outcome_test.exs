defmodule Fleet.Pilot.MergeOutcomeTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.MergeOutcome

  # Classification STRUCTURELLE (champs PR, jamais le message d'erreur). Chaque classe correspond à une
  # cause RÉELLE distincte d'un échec de merge — le fourre-tout « conflit » (→ eng rebase impossible →
  # mur 2026-07-07) est remplacé par cette somme fermée. Valeurs de champs VÉRIFIÉES sur forge test.

  test ":merged — déjà mergée (course multi-acteur / replay) prime sur tout" do
    # merged implique state closed ; l'ordre des gardes fait gagner :merged (no-op idempotent, pas :closed).
    assert MergeOutcome.classify(%{"merged" => true, "state" => "closed", "mergeable" => false}) ==
             :merged
  end

  test ":closed — fermée sans merge = annulation humaine" do
    assert MergeOutcome.classify(%{"merged" => false, "state" => "closed", "mergeable" => true}) ==
             :closed
  end

  test ":draft AVANT :mergeable — un draft porte mergeable:false mais n'est PAS un conflit" do
    # LE cas qui cassait le fixe naïf « mergeable:false = conflit » : sans l'ordre draft-d'abord, un
    # draft parti en résolution-de-conflit → eng rebase impossible → mur (prouvé forge : draft merge = 405 WIP).
    assert MergeOutcome.classify(%{"state" => "open", "draft" => true, "mergeable" => false}) ==
             :draft
  end

  test ":conflict — vrai conflit git (mergeable:false, pas draft)" do
    assert MergeOutcome.classify(%{"state" => "open", "draft" => false, "mergeable" => false}) ==
             :conflict
  end

  test ":policy — git mergeable mais la forge refuse (approbations retirées par re-request / CI)" do
    # Le cas hello-kitty : mergeable:true (git OK) MAIS branch-protection refuse → surtout PAS :conflict.
    assert MergeOutcome.classify(%{"state" => "open", "draft" => false, "mergeable" => true}) ==
             :policy
  end

  test ":unknown — mergeable indéterminé (null, calcul forge en cours) → ne rien inventer" do
    assert MergeOutcome.classify(%{"state" => "open", "draft" => false, "mergeable" => nil}) ==
             :unknown

    assert MergeOutcome.classify(%{"state" => "open"}) == :unknown
  end
end
