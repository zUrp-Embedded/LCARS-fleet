defmodule Fleet.Pilot.StepRunConsumer.VerdictCorrectionFlagTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Verifie la configuration chargee hors du setup qui active la correction.
  Fichier separe de verdict_correction_test pour ne pas lire sa propre surcharge.
  Le fallback false ne distingue pas une cle absente d'une cle explicitement desarmee.
  """

  test "le défaut est ÉTEINT — et voici la condition qui le fera basculer" do
    # Avant activation par defaut : jouer une enveloppe volontairement malformee sur un banc,
    # flag active manuellement ; verifier reception du vrai pointeur/message de schema,
    # puis passage du verdict re-emballe jusqu'a la revue native.
    # Livrer config.exs et l'assertion de defaut dans un commit dedie, avec cette preuve :
    # une config active seulement sur le banc ne prouve pas celle que la branche livre.
    assert Application.get_env(:lcars_fleet, :pilot_verdict_correction_pass?, false) == false,
           "le barreau a été armé — si c'est voulu, ce test doit être RETOURNÉ et la condition de " <>
             "bascule ci-dessus réécrite avec ce qui l'a effectivement remplie"
  end

  test "TÉMOIN — le barreau voisin, lui, EST armé : ce test sait dire les deux" do
    # Le voisin doit etre true. Cela ne detecte pas une faute de cle dans le test de correction.
    assert Application.get_env(:lcars_fleet, :pilot_verdict_exception_pass?) == true
  end
end
