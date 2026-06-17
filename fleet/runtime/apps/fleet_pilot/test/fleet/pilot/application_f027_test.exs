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

  # F-027 : avant, `stage_dispatch?: true` + config incomplète → `stage_children` rendait `[]` en
  # SILENCE → l'app pilot démarrait « verte » sans Poller/HopConsumer (rail forge mort, zéro log).
  # Désormais : l'opérateur a DEMANDÉ le mode stage → config incomplète = deploy cassé → raise au boot.

  test "stage_dispatch? true sans :poll_repo → raise (plus de rail mort silencieux)" do
    Application.put_env(:fleet_pilot, :stage_dispatch?, true)
    Application.delete_env(:fleet_pilot, :poll_repo)

    assert_raise RuntimeError, ~r/poll_repo absent/, fn ->
      Fleet.Pilot.Application.start(:normal, [])
    end
  end

  test "stage_dispatch? true + repo mais remote irrésolu (pas de FORGE_BASE_URL) → raise" do
    Application.put_env(:fleet_pilot, :stage_dispatch?, true)
    Application.put_env(:fleet_pilot, :poll_repo, "fleet/x")
    Application.delete_env(:fleet_pilot, :hop_remote)
    Application.put_env(:fleet_pilot, :forge, [])

    assert_raise RuntimeError, ~r/remote irrésolu/, fn ->
      Fleet.Pilot.Application.start(:normal, [])
    end
  end
end
