defmodule Fleet.EventRouter.CatalogF008Test do
  # async: false — mute la config globale :load_event_registry / :events_yaml_path.
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Catalog

  setup do
    prev_load = Application.get_env(:fleet_event_router, :load_event_registry)
    prev_path = Application.get_env(:fleet_event_router, :events_yaml_path)

    on_exit(fn ->
      restore(:load_event_registry, prev_load)
      restore(:events_yaml_path, prev_path)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fleet_event_router, key)
  defp restore(key, val), do: Application.put_env(:fleet_event_router, key, val)

  # F-008 (Pattern A crash-boot) : avant, un events.yaml absent/invalide WARNait puis rendait :ok →
  # registry vide → le Bus broadcastait TOUT sans validation (deploy « vert » mais registry mort).
  # `do_load` n'est atteint qu'avec `load_event_registry: true` (prod/dev) → désormais il raise.
  test "F-008 : events.yaml absent + registry voulu (prod) → raise (plus d'ACK silencieux)" do
    Application.put_env(:fleet_event_router, :load_event_registry, true)
    Application.put_env(:fleet_event_router, :events_yaml_path, "/nonexistent/events-xyz.yaml")

    assert_raise RuntimeError, ~r/events\.yaml absent ou invalide/, fn ->
      Catalog.load!()
    end
  end

  test "F-008 : load_event_registry=false (test/maintenance) → no-op :ok (pas de raise)" do
    Application.put_env(:fleet_event_router, :load_event_registry, false)
    assert :ok = Catalog.load!()
  end
end
