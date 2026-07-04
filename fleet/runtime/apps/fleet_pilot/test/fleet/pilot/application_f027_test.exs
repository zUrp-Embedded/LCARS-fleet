defmodule Fleet.Pilot.ApplicationF027Test do
  # async: false — mute la config globale :fleet_pilot (step_dispatch?/poll_repo/...).
  use ExUnit.Case, async: false

  @keys [:step_dispatch?, :poll_repo, :hop_remote, :forge]

  setup do
    # Les tests posent ces clés eux-mêmes ; on n'enregistre ici que leur restauration.
    Enum.each(@keys, &Fleet.Pilot.TestEnv.restore_env_on_exit(:fleet_pilot, &1))
    :ok
  end

  # F-027 + F-037 : avant, `step_dispatch?: true` + config incomplète → `step_children` rendait `[]` en
  # SILENCE → l'app pilot démarrait « verte » sans Poller/StepRunConsumer (rail forge mort, zéro log). Désormais :
  # l'opérateur a DEMANDÉ le mode step → config incomplète = deploy cassé → raise au boot. F-037 a re-pointé
  # la garde : ce n'est plus `:poll_repo` (le poller DÉCOUVRE par topic) ni un remote figé (per-step-run), mais la
  # forge `base_url` — sans elle, ni découverte (`search_repos_by_topic`) ni push (remote per-step-run) ne marchent.

  test "F-037 : step_dispatch? true sans forge base_url (:forge absent) → raise (rail mort évité)" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.delete_env(:fleet_pilot, :forge)

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.start(:normal, [])
    end
  end

  test "F-037 : step_dispatch? true mais :forge sans :base_url → raise" do
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, token: "x")

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.start(:normal, [])
    end
  end

  test "F-037 : :poll_repo n'est PLUS requis (découverte par topic) — pas de raise sur son absence seule" do
    # La garde ne dépend plus de :poll_repo. Avec une forge base_url présente, l'absence de :poll_repo ne
    # déclenche RIEN (on vérifie via step_children! qu'aucune RuntimeError « base_url » n'est levée).
    Application.put_env(:fleet_pilot, :step_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")
    Application.delete_env(:fleet_pilot, :poll_repo)

    # On exerce la résolution des child-specs (sans démarrer le superviseur, qui enregistrerait les
    # singletons sous leurs noms globaux et entrerait en conflit). `:poll_repo` absent → pas de raise.
    children = Fleet.Pilot.Application.step_children_for_test()
    assert Enum.any?(children, &match?({Fleet.Pilot.Poller, _}, &1))
    assert Enum.any?(children, &match?({Fleet.Pilot.StepRunConsumer, _}, &1))
  end
end
