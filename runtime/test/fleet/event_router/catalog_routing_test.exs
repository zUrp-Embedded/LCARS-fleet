defmodule Fleet.EventRouter.CatalogRoutingTest do
  @moduledoc """
  Checks loaded source/type routes, incident metadata and schema/semantic refusals.
  Calls the loader directly; does not exercise incident consumers or whole-node boot failure.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.EventRouter.Catalog

  setup do
    prior_types = Bus.authorized_event_types()
    prior_routing = Bus.event_routing()

    on_exit(fn ->
      Bus.set_authorized_event_types(prior_types)
      Bus.set_event_routing(prior_routing)
    end)

    :ok
  end

  test "the CANON events.yaml loads: the 7 routed entries land in Bus.event_routing with their data" do
    # Real canon, real loader path (config points the loader at the bundled priv by default).
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert :ok = Catalog.load!()
    routing = Bus.event_routing()

    # Immediate routes carry the escalation kind required by the consumer.
    assert %{
             action: :incident,
             incident: %{
               op: "workflow_map",
               subject: "workflow_map",
               gate: :immediate,
               escalate_kind: :workflow_map_failed
             }
           } = routing[{:workflow, :"workflow_map.failed"}]

    # Card/declaration routes retain separate dedup operation names and repository subjects.
    assert %{
             action: :incident,
             incident: %{
               op: "card",
               subject: "repo",
               gate: :immediate,
               escalate_kind: :project_card_failed
             }
           } = routing[{:project, :"project.card_failed"}]

    assert %{
             action: :incident,
             incident: %{
               op: "declaration",
               subject: "repo",
               gate: :immediate,
               escalate_kind: :project_declaration_invalid
             }
           } = routing[{:project, :"project.declaration_invalid"}]

    # Check all loaded actions; this assertion does not pin the count in the historical title.
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
      Catalog.load!()
    end
  end

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

    assert_raise RuntimeError, fn -> Catalog.load!() end
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
      Catalog.load!()
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

    assert_raise RuntimeError, ~r/INVALID against events/, fn ->
      Catalog.load!()
    end
  end
end
