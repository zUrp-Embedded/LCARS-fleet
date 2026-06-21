defmodule Fleet.Pilot.ApplicationF027Test do
  # async: false — mute la config globale :fleet_pilot (stage_dispatch?/poll_repo/...).
  use ExUnit.Case, async: false

  @keys [:stage_dispatch?, :poll_repo, :hop_remote, :forge]

  setup do
    prev = Map.new(@keys, fn k -> {k, Application.get_env(:fleet_pilot, k)} end)

    on_exit(fn ->
      Enum.each(@keys, fn k ->
        case Map.get(prev, k) do
          nil -> Application.delete_env(:fleet_pilot, k)
          v -> Application.put_env(:fleet_pilot, k, v)
        end
      end)
    end)

    :ok
  end

  # F-027 + F-037 : avant, `stage_dispatch?: true` + config incomplète → `stage_children` rendait `[]` en
  # SILENCE → l'app pilot démarrait « verte » sans Poller/HopConsumer (rail forge mort, zéro log). Désormais :
  # l'opérateur a DEMANDÉ le mode stage → config incomplète = deploy cassé → raise au boot. F-037 a re-pointé
  # la garde : ce n'est plus `:poll_repo` (le poller DÉCOUVRE par topic) ni un remote figé (per-hop), mais la
  # forge `base_url` — sans elle, ni découverte (`search_repos_by_topic`) ni push (remote per-hop) ne marchent.

  test "F-037 : stage_dispatch? true sans forge base_url (:forge absent) → raise (rail mort évité)" do
    Application.put_env(:fleet_pilot, :stage_dispatch?, true)
    Application.delete_env(:fleet_pilot, :forge)

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.start(:normal, [])
    end
  end

  test "F-037 : stage_dispatch? true mais :forge sans :base_url → raise" do
    Application.put_env(:fleet_pilot, :stage_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, token: "x")

    assert_raise RuntimeError, ~r/base_url/, fn ->
      Fleet.Pilot.Application.start(:normal, [])
    end
  end

  test "F-037 : :poll_repo n'est PLUS requis (découverte par topic) — pas de raise sur son absence seule" do
    # La garde ne dépend plus de :poll_repo. Avec une forge base_url présente, l'absence de :poll_repo ne
    # déclenche RIEN (on vérifie via stage_children! qu'aucune RuntimeError « base_url » n'est levée).
    Application.put_env(:fleet_pilot, :stage_dispatch?, true)
    Application.put_env(:fleet_pilot, :forge, base_url: "http://forge.local")
    Application.delete_env(:fleet_pilot, :poll_repo)

    # On exerce la résolution des child-specs (sans démarrer le superviseur, qui enregistrerait les
    # singletons sous leurs noms globaux et entrerait en conflit). `:poll_repo` absent → pas de raise.
    children = Fleet.Pilot.Application.stage_children_for_test()
    assert Enum.any?(children, &match?({Fleet.Pilot.Poller, _}, &1))
    assert Enum.any?(children, &match?({Fleet.Pilot.HopConsumer, _}, &1))
  end
end
