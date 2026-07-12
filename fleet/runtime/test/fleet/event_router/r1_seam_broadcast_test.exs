defmodule Fleet.EventRouter.R1SeamBroadcastTest do
  @moduledoc """
  R1 / BL-027 — couture **registry + validation broadcast** (fork « subscribers
  directs = canon » : la table de dispatch est retirée, `events.yaml` = registry).

  Le verrou anti-récurrence n'est plus « Dispatch refuse de booter sur handler
  fantôme » (T4 historique) mais « un event émis hors registry est rejeté
  fail-loud au broadcast » : `Fleet.EventRouter.Catalog.load!/0` peuple
  `authorized_event_types` depuis events.yaml → `Bus.broadcast/2` raise
  `UnregisteredError` sur tout type non-registré. Couture testée SANS stub : vrai
  Catalog.load! + vrai Bus.broadcast/2.

  Tag `:r1_seam` — `mix test --only r1_seam`.
  """
  use ExUnit.Case, async: false

  @moduletag :r1_seam

  alias Fleet.EventRouter.{Bus, Catalog}

  @tag :tmp_dir
  test "T4 — registry chargé (Catalog) → Bus.broadcast/2 fail-loud sur type non-registré",
       %{tmp_dir: tmp} do
    path = Path.join(tmp, "events.yaml")
    File.write!(path, "events:\n  pod.completed: []\n")

    Fleet.EventRouter.TestEnv.put_env_restoring(:fleet_event_router, :events_yaml_path, path)
    Fleet.EventRouter.TestEnv.put_env_restoring(:fleet_event_router, :load_event_registry, true)

    # Reset le registry global pour ne pas polluer les autres tests.
    on_exit(fn -> Bus.set_authorized_event_types(MapSet.new()) end)

    :ok = Catalog.load!()

    registered = Fleet.Event.new(:spawner, :"pod.completed")

    # Source valide (:spawner) mais TYPE hors registry : `new/3` la construit (l'enum du `type`
    # n'est pas enforcé), c'est `Bus.broadcast` qui doit rejeter — ce que ce test vérifie.
    unregistered = Fleet.Event.new(:spawner, :"phantom.unregistered.type")

    # Type registré → passe.
    assert :ok = Bus.broadcast("fleet.events", registered)

    # Type hors registry → fail-loud (verrou anti-récurrence).
    assert_raise Fleet.Event.UnregisteredError, fn ->
      Bus.broadcast("fleet.events", unregistered)
    end
  end
end
