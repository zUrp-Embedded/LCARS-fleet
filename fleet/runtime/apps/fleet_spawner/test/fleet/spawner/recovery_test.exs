defmodule Fleet.Spawner.RecoveryTest do
  # async: true — `recovery_action/1` est pure (fonction de la seule phase) ; plus
  # aucune mutation de config globale (le gate `:recovery_resume_enabled` a disparu).
  use ExUnit.Case, async: true

  alias Fleet.Spawner.Pod.Recovery

  # `recovery_action/1` pure : la PHASE seule décide. Phase terminale → :release
  # (rien à relancer) ; tout le reste → :recreate (from scratch, session neuve).
  # Plus de chemin `:resume` : `--resume` sur une session morte côté serveur = pod
  # zombie (prouvé live). Un (re)spawn en vol reroll ; la tâche reste en queue et
  # re-drive un REPL neuf. Sous `:temporary` le supervisor ne ressuscite jamais ;
  # (re)spawn délibéré → décision explicite.

  test "phase terminale → :release (rien à relancer)" do
    assert :release = Recovery.recovery_action(:succeeded)
    assert :release = Recovery.recovery_action(:released)
    assert :release = Recovery.recovery_action(:killed)
  end

  test "phase :failed / :pending / ambiguë → :recreate (from scratch, session neuve)" do
    assert :recreate = Recovery.recovery_action(:failed)
    assert :recreate = Recovery.recovery_action(:pending)
    assert :recreate = Recovery.recovery_action(:allocating)
  end

  test "phase EN VOL → :recreate (backend mort sous :temporary, session morte irrécupérable)" do
    assert :recreate = Recovery.recovery_action(:launching)
    assert :recreate = Recovery.recovery_action(:monitoring)
    assert :recreate = Recovery.recovery_action(:extracting)
    assert :recreate = Recovery.recovery_action(:releasing)
  end
end
