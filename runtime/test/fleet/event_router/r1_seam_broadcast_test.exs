defmodule Fleet.EventRouter.R1SeamBroadcastTest do
  @moduledoc """
  R1 / BL-027 — **registry + broadcast validation** seam ("direct subscribers =
  canon" fork: there is no dispatch table, `events.yaml` IS the registry).

  The anti-recurrence lock (T4): an event emitted outside the registry is rejected
  fail-loud at broadcast — `Fleet.EventRouter.Catalog.load!/0` populates
  `authorized_event_types` from events.yaml → `Bus.broadcast/2` raises
  `UnregisteredError` on any unregistered type. Seam tested WITHOUT stubs: real
  Catalog.load! + real Bus.broadcast/2.

  Tag `:r1_seam` — `mix test --only r1_seam`.
  """
  use ExUnit.Case, async: false

  @moduletag :r1_seam

  alias Fleet.EventRouter.{Bus, Catalog}

  @tag :tmp_dir
  test "T4 — registry loaded (Catalog) → Bus.broadcast/2 fail-loud on unregistered type",
       %{tmp_dir: tmp} do
    path = Path.join(tmp, "events.yaml")
    File.write!(path, "events:\n  pod.completed: []\n")

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_load_event_registry, true)

    # Reset the global registry to avoid polluting the other tests.
    on_exit(fn -> Bus.set_authorized_event_types(MapSet.new()) end)

    :ok = Catalog.load!()

    registered = Fleet.Event.new(:spawner, :"pod.completed")

    # Valid source (:spawner) but TYPE outside the registry: `new/3` builds it (the `type`
    # enum is not enforced); `Bus.broadcast` must reject — which this test verifies.
    unregistered = Fleet.Event.new(:spawner, :"phantom.unregistered.type")

    # Registered type → passes.
    assert :ok = Bus.broadcast("fleet.events", registered)

    # Type outside the registry → fail-loud (anti-recurrence lock).
    assert_raise Fleet.Event.UnregisteredError, fn ->
      Bus.broadcast("fleet.events", unregistered)
    end
  end
end
