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

  test "the CANON events.yaml loads: the 5 routed entries land in Bus.event_routing with their data" do
    # Real canon, real loader path (config points the loader at the bundled priv by default).
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert :ok = Fleet.EventRouter.Catalog.load!()
    routing = Bus.event_routing()

    # Bascule 2026-08-19 (brouette) : plus une route de severite max — une route incident a porte IMMEDIATE
    # declaree, avec le kind nomme (exige au boot : la table kind_describe est close).
    assert %{
             action: :incident,
             incident: %{
               op: "workflow_map",
               subject: "workflow_map",
               gate: :immediate,
               escalate_kind: :workflow_map_failed
             }
           } = routing[{:workflow, :"workflow_map.failed"}]

    # (pod.drift, audit.verdict et les broadcasts de severite max sont partis — brouette
    # 2026-08-19. Les cinq routes restantes sont toutes `action: incident`.)
    assert routing |> Map.values() |> Enum.all?(&(&1.action == :incident))
  end

  @tag :tmp_dir
  test "DPF-13: a route with a non-canonical source → boot REFUSED", %{tmp_dir: tmp} do
    path = Path.join(tmp, "events.yaml")

    File.write!(path, """
    events:
      pod.drift:
        source: typo_source
        action: incident
        incident: {op: pod, subject: pod_id}
    """)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert_raise RuntimeError, ~r/not a canonical source/, fn ->
      Fleet.EventRouter.Catalog.load!()
    end
  end

  # (Les gardes JG-012/DPF-14 du rail de severite max sont parties avec lui — brouette
  # 2026-08-19. Les gardes survivantes dans leur esprit, ci-dessous : un `gate` hors enum refuse
  # au boot, et gate=immediate SANS escalate_kind refuse au boot — la table `kind_describe` est
  # close, un kind sans clause crasherait a la PREMIERE escalade au lieu du boot, la panne exacte
  # de :awaits_arch_stuck.)

  @tag :tmp_dir
  test "un gate hors enum → boot REFUSE", %{tmp_dir: tmp} do
    path = Path.join(tmp, "events.yaml")

    File.write!(path, """
    events:
      pod.failed:
        source: spawner
        action: incident
        incident: {op: pod, subject: pod_id, gate: tout_de_suite}
    """)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert_raise RuntimeError, fn -> Fleet.EventRouter.Catalog.load!() end
  end

  @tag :tmp_dir
  test "gate=immediate SANS escalate_kind → boot REFUSE (la table des kinds est close)", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "events.yaml")

    File.write!(path, """
    events:
      pod.failed:
        source: spawner
        action: incident
        incident: {op: pod, subject: pod_id, gate: immediate}
    """)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert_raise RuntimeError, ~r/without escalate_kind/, fn ->
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
