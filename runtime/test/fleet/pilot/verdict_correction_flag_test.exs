defmodule Fleet.Pilot.StepRunConsumer.VerdictCorrectionFlagTest do
  use ExUnit.Case, async: false

  @moduledoc """
  LA DETTE DU BARREAU ÉTEINT, ÉCRITE LÀ OÙ ON LA RELIT.

  Un mécanisme livré éteint est un mécanisme qui peut ne jamais être allumé : le code vieillit, le
  contexte se perd, et un jour personne ne sait plus si l'extinction était une précaution ou un
  aveu. Le handoff ne suffit pas — il se lit une fois. Un test se lit à chaque modification.

  ## Fichier SÉPARÉ, et c'est la raison d'être de ce module

  `verdict_correction_test.exs` ARME le drapeau dans son `setup`, pour exercer la passe. Une
  assertion sur le DÉFAUT n'a donc aucun sens là-bas : elle lirait la valeur du test voisin. Ici,
  rien ne touche la clef, donc ce qui est lu est ce qu'un déploiement obtient.
  """

  test "le défaut est ÉTEINT — et voici la condition qui le fera basculer" do
    # LA CONDITION DE BASCULE, à remplir AVANT de toucher au défaut :
    #
    #   1. une enveloppe de verdict volontairement malformée, jouée de bout en bout sur un banc,
    #      avec `:pilot_verdict_correction_pass?` armé à la main ;
    #   2. le juge reçoit le motif RÉEL de la violation (pointeur JSON + message de schéma), et non
    #      le texte de repli — c'est la promesse centrale de cette passe ;
    #   3. il ré-emballe, et le verdict corrigé traverse le rail jusqu'à sa revue native.
    #
    # Le jour où c'est fait : poser la ligne dans `config.exs`, RETOURNER ce test (il devient
    # `refute … == false`, comme celui de `VerdictException`), et le faire dans un COMMIT DÉDIÉ.
    # Le précédent est là pour une raison mesurée : la preuve de la zone grise avait tourné avec le
    # drapeau déjà à `true` sur le banc alors que l'arbre disait `false` — donc la configuration
    # prouvée n'était pas celle livrée, et un preneur de la branche obtenait un autre barreau.
    assert Application.get_env(:lcars_fleet, :pilot_verdict_correction_pass?, false) == false,
           "le barreau a été armé — si c'est voulu, ce test doit être RETOURNÉ et la condition de " <>
             "bascule ci-dessus réécrite avec ce qui l'a effectivement remplie"
  end

  test "TÉMOIN — le barreau voisin, lui, EST armé : ce test sait dire les deux" do
    # Sans ce témoin, l'assertion ci-dessus passerait aussi si `get_env` rendait toujours `false`
    # — par exemple si la clef était mal orthographiée. `VerdictException` a été armé le
    # 2026-08-19 après sa preuve de bout en bout ; lire `true` ici prouve que l'instrument
    # distingue un barreau armé d'un barreau éteint.
    assert Application.get_env(:lcars_fleet, :pilot_verdict_exception_pass?) == true
  end
end
