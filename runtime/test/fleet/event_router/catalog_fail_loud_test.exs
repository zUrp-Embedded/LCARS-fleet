defmodule Fleet.EventRouter.CatalogFailLoudTest do
  # async: false — mutates the global :load_event_registry / :events_yaml_path config.
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Catalog
  alias Fleet.TestEnv

  setup do
    # Tests set :load_event_registry / :events_yaml_path themselves; capture-restore only.
    TestEnv.restore_env_on_exit(:lcars_fleet, :event_router_load_event_registry)
    TestEnv.restore_env_on_exit(:lcars_fleet, :event_router_events_yaml_path)
    :ok
  end

  # Call the enabled loader directly: missing input must not leave a permissive empty registry.
  test "events.yaml absent + registry wanted (prod) → raise (no silent ACK)" do
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)

    Application.put_env(
      :lcars_fleet,
      :event_router_events_yaml_path,
      "/nonexistent/events-xyz.yaml"
    )

    assert_raise RuntimeError, ~r/events\.yaml absent or invalid/, fn ->
      Catalog.load!()
    end
  end

  test "load_event_registry=false (test/maintenance) → no-op :ok (no raise)" do
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, false)
    assert :ok = Catalog.load!()
  end

  # Parsed-but-empty input must also be refused, before installing an empty authorized set.
  @tag :tmp_dir
  test "events.yaml EMPTY (events: {}) + registry wanted (prod) → raise (empty-registry fail-open closed)",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.yaml")
    File.write!(path, "events: {}\n")

    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    Application.put_env(:lcars_fleet, :event_router_events_yaml_path, path)

    assert_raise RuntimeError, ~r/events\.yaml EMPTY/, fn ->
      Catalog.load!()
    end
  end

  # Preregistration distinguishes an empty map from an unreadable file; only load! rejects emptiness.
  @tag :tmp_dir
  test "event_type_strings/0 returns [] on EMPTY events.yaml (preregister unchanged, no raise)",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.yaml")
    File.write!(path, "events: {}\n")

    Application.put_env(:lcars_fleet, :event_router_events_yaml_path, path)

    assert [] = Catalog.event_type_strings()
  end

  # Preregistration still runs when loading is disabled. Diagnose malformed input here,
  # rather than later as an unknown atom in an event consumer. This fixture is valid YAML
  # with the wrong events shape, despite the historical "unparseable" title.
  @tag :tmp_dir
  test "event_type_strings/0 RAISES on an unparseable events.yaml — same fault, same treatment as load!/0",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.yaml")
    File.write!(path, "events: [this is a list, not a map]\n")

    Application.put_env(:lcars_fleet, :event_router_events_yaml_path, path)

    assert_raise RuntimeError, ~r/events\.yaml absent or invalid/, fn ->
      Catalog.event_type_strings()
    end
  end

  @tag :tmp_dir
  test "event_type_strings/0 RAISES on an ABSENT events.yaml (the disabled-registry blind spot)",
       %{tmp_dir: tmp_dir} do
    Application.put_env(
      :lcars_fleet,
      :event_router_events_yaml_path,
      Path.join(tmp_dir, "nowhere.yaml")
    )

    assert_raise RuntimeError, ~r/no event atom could be pre-registered/, fn ->
      Catalog.event_type_strings()
    end
  end
end
