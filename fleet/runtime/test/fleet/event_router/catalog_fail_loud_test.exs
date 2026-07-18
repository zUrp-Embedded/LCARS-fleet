defmodule Fleet.EventRouter.CatalogFailLoudTest do
  # async: false — mutates the global :load_event_registry / :events_yaml_path config.
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Catalog
  alias Fleet.EventRouter.TestEnv

  setup do
    # Tests set :load_event_registry / :events_yaml_path themselves; capture-restore only.
    TestEnv.restore_env_on_exit(:fleet_event_router, :load_event_registry)
    TestEnv.restore_env_on_exit(:fleet_event_router, :events_yaml_path)
    :ok
  end

  # Locks the crash-boot contract: an absent/invalid events.yaml in a real regime MUST raise —
  # a warn-and-:ok would leave an empty registry and a Bus broadcasting EVERY type without
  # validation (green deploy, dead registry). `do_load` is only reached with
  # `load_event_registry: true` (prod/dev).
  test "events.yaml absent + registry wanted (prod) → raise (no silent ACK)" do
    Application.put_env(:fleet_event_router, :load_event_registry, true)
    Application.put_env(:fleet_event_router, :events_yaml_path, "/nonexistent/events-xyz.yaml")

    assert_raise RuntimeError, ~r/events\.yaml absent or invalid/, fn ->
      Catalog.load!()
    end
  end

  test "load_event_registry=false (test/maintenance) → no-op :ok (no raise)" do
    Application.put_env(:fleet_event_router, :load_event_registry, false)
    assert :ok = Catalog.load!()
  end

  # Twin fail-open hole: a VALID but EMPTY events.yaml (`events: {}`) parses OK (`{:ok, %{}}`);
  # an empty MapSet would leave the Bus (permissive on an empty registry) broadcasting EVERY
  # type without validation — green boot, dead registry. In a real regime `do_load` must raise
  # exactly like an absent file.
  @tag :tmp_dir
  test "events.yaml EMPTY (events: {}) + registry wanted (prod) → raise (empty-registry fail-open closed)",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.yaml")
    File.write!(path, "events: {}\n")

    Application.put_env(:fleet_event_router, :load_event_registry, true)
    Application.put_env(:fleet_event_router, :events_yaml_path, path)

    assert_raise RuntimeError, ~r/events\.yaml EMPTY/, fn ->
      Catalog.load!()
    end
  end

  # Non-régression de l'AUTRE lecteur du parse : `event_type_strings/0` (source de
  # `preregister_event_atoms/0`) doit toujours rendre `[]` sur un events.yaml vide — il n'a rien à
  # pré-enregistrer et NE doit PAS fail-loud (sinon `Application.preregister_event_atoms/0` casserait).
  @tag :tmp_dir
  test "event_type_strings/0 returns [] on EMPTY events.yaml (preregister unchanged, no raise)",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.yaml")
    File.write!(path, "events: {}\n")

    Application.put_env(:fleet_event_router, :events_yaml_path, path)

    assert [] = Catalog.event_type_strings()
  end
end
