defmodule Fleet.EventRouter.CatalogRoutingTest do
  @moduledoc """
  The declarative routing table (audit B-05): the registry canon carries
  `event + source → classification/action/threshold/sink`, the Catalog loads it validated,
  and the numbers/sinks live in DATA — never in a consumer clause.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  setup do
    prior_types = Bus.authorized_event_types()
    prior_routing = Bus.event_routing()

    on_exit(fn ->
      Bus.set_authorized_event_types(prior_types)
      Bus.set_event_routing(prior_routing)
    end)

    :ok
  end

  test "the CANON events.yaml loads: the 10 routed entries land in Bus.event_routing with their data" do
    # Real canon, real loader path (config points the loader at the bundled priv by default).
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert :ok = Fleet.EventRouter.Catalog.load!()
    routing = Bus.event_routing()

    # The drift threshold is DATA — the number 3 lives HERE, not in DriftMonitor.
    assert %{
             action: :cat5,
             cat5_source: :pod_drift,
             threshold: %{counter: "drift_count", min: 3}
           } = routing[{:spawner, :"pod.drift"}]

    assert %{action: :cat5, cat5_source: :workflow_map_failed, threshold: nil} =
             routing[{:workflow, :"workflow_map.failed"}]

    assert %{action: :coord_decision} = routing[{:workflow, :"audit.verdict"}]
  end

  @tag :tmp_dir
  test "a cat5 route whose audit_cat5_<tag> key is NOT registered → boot REFUSED (fail-loud)", %{
    tmp_dir: tmp
  } do
    # The broadcast type is SYNTHESIZED from the tag: an unregistered synthesis would be refused
    # at emit — Catalog refuses it at BOOT instead (a chain wired to a dead broadcast is a broken
    # deploy, not a runtime surprise).
    path = Path.join(tmp, "events.yaml")

    File.write!(path, """
    events:
      pod.drift:
        source: spawner
        action: cat5
        cat5_source: ghost_tag
    """)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert_raise RuntimeError, ~r/audit_cat5_ghost_tag.*NOT a\s+registered/s, fn ->
      Fleet.EventRouter.Catalog.load!()
    end
  end

  @tag :tmp_dir
  test "DPF-13: a route with a non-canonical source → boot REFUSED", %{tmp_dir: tmp} do
    path = Path.join(tmp, "events.yaml")

    File.write!(path, """
    events:
      pod.drift:
        source: typo_source
        action: coord_decision
    """)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert_raise RuntimeError, ~r/not a canonical source/, fn ->
      Fleet.EventRouter.Catalog.load!()
    end
  end

  @tag :tmp_dir
  test "DPF-14: cat5_source on a non-cat5 action → boot REFUSED", %{tmp_dir: tmp} do
    path = Path.join(tmp, "events.yaml")

    File.write!(path, """
    events:
      pod.drift:
        source: spawner
        action: coord_decision
        cat5_source: orphan_tag
    """)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert_raise RuntimeError, ~r/carries cat5_source/, fn ->
      Fleet.EventRouter.Catalog.load!()
    end
  end

  @tag :tmp_dir
  test "a schema-invalid routing entry (unknown action) → boot REFUSED", %{tmp_dir: tmp} do
    path = Path.join(tmp, "events.yaml")

    File.write!(path, """
    events:
      pod.drift:
        source: spawner
        action: teleport
    """)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert_raise RuntimeError, ~r/INVALID against events-v1/, fn ->
      Fleet.EventRouter.Catalog.load!()
    end
  end
end
