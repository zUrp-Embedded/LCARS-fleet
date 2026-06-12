defmodule Fleet.Spawner.RecoveryTest do
  # async: false — les tests du gate `:recovery_resume_enabled` mutent la config globale.
  use ExUnit.Case, async: false

  alias Fleet.Spawner.Pod

  # DN-recovery B + F-C4b-1 : `recovery_action/2` pure. La PHASE décide release vs
  # in-flight ; pour l'in-flight, le SCOPE + le GATE décident resume vs recreate
  # (one-shot reroll toujours ; pipe/forever resume si gate ON). Sous `:temporary`
  # le supervisor ne ressuscite jamais ; (re)spawn délibéré → décision explicite.

  test "phase terminale → :release (rien à relancer)" do
    assert :release = Pod.recovery_action(:succeeded)
    assert :release = Pod.recovery_action(:released)
    assert :release = Pod.recovery_action(:killed)
  end

  test "phase :failed / :pending / ambiguë → :recreate (from scratch, session neuve)" do
    assert :recreate = Pod.recovery_action(:failed)
    assert :recreate = Pod.recovery_action(:pending)
    assert :recreate = Pod.recovery_action(:allocating)
  end

  # BL-035 (dogfood F7) : le DÉFAUT du gate est désormais OFF (`--resume` sur session morte = pod
  # zombie, PROUVÉ live). Donc en vol → `:recreate` par défaut. La décision `:resume` n'est atteinte
  # que si le gate est explicitement ON (opt-in).
  test "DÉFAUT (gate OFF, BL-035) : phase en vol → :recreate (session morte irrécupérable)" do
    assert :recreate = Pod.recovery_action(:launching)
    assert :recreate = Pod.recovery_action(:monitoring, "pipe")
    assert :recreate = Pod.recovery_action(:monitoring, "forever")
    assert :recreate = Pod.recovery_action(:releasing, nil)
  end

  test "gate ON (opt-in) + phase en vol, scope nil/inconnu → :resume" do
    Application.put_env(:fleet_spawner, :recovery_resume_enabled, true)
    on_exit(fn -> Application.delete_env(:fleet_spawner, :recovery_resume_enabled) end)

    assert :resume = Pod.recovery_action(:launching)
    assert :resume = Pod.recovery_action(:monitoring)
    assert :resume = Pod.recovery_action(:extracting)
    assert :resume = Pod.recovery_action(:releasing)
  end

  test "gate ON (opt-in) + scope pipe/forever en vol → :resume (préserve le travail mid-mandat)" do
    Application.put_env(:fleet_spawner, :recovery_resume_enabled, true)
    on_exit(fn -> Application.delete_env(:fleet_spawner, :recovery_resume_enabled) end)

    assert :resume = Pod.recovery_action(:monitoring, "pipe")
    assert :resume = Pod.recovery_action(:monitoring, "forever")
    assert :resume = Pod.recovery_action(:launching, "pipe")
  end

  test "scope one-shot en vol → :recreate (clear-policy /clear → pas de contexte, sessionId divergent)" do
    assert :recreate = Pod.recovery_action(:monitoring, "one-shot")
    assert :recreate = Pod.recovery_action(:launching, "one-shot")
    assert :recreate = Pod.recovery_action(:extracting, "one-shot")
  end

  test "gate :recovery_resume_enabled=false → :recreate PARTOUT (escape-hatch F-C4b-1)" do
    Application.put_env(:fleet_spawner, :recovery_resume_enabled, false)
    on_exit(fn -> Application.delete_env(:fleet_spawner, :recovery_resume_enabled) end)

    # même pipe/forever (qui resumerait gate ON) reroll quand le gate est OFF.
    assert :recreate = Pod.recovery_action(:monitoring, "pipe")
    assert :recreate = Pod.recovery_action(:monitoring, "forever")
    assert :recreate = Pod.recovery_action(:monitoring, nil)
    # les phases terminales/échec ne changent pas (jamais resume de toute façon).
    assert :release = Pod.recovery_action(:succeeded, "pipe")
    assert :recreate = Pod.recovery_action(:failed, "pipe")
  end
end
