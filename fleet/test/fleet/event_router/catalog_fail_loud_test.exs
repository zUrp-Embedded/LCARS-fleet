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

  # Locks the crash-boot contract: an absent/invalid events.yaml in a real regime MUST raise —
  # a warn-and-:ok would leave an empty registry and a Bus broadcasting EVERY type without
  # validation (green deploy, dead registry). `do_load` is only reached with
  # `load_event_registry: true` (prod/dev).
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

  # Twin fail-open hole: a VALID but EMPTY events.yaml (`events: {}`) parses OK (`{:ok, %{}}`);
  # an empty MapSet would leave the Bus (permissive on an empty registry) broadcasting EVERY
  # type without validation — green boot, dead registry. In a real regime `do_load` must raise
  # exactly like an absent file.
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

  # Non-regression for the OTHER reader of the parse: `event_type_strings/0` (source of
  # `preregister_event_atoms/0`) must still return `[]` on an empty events.yaml — it has nothing to
  # preregister and must NOT fail-loud (otherwise `Application.preregister_event_atoms/0` would break).
  @tag :tmp_dir
  test "event_type_strings/0 returns [] on EMPTY events.yaml (preregister unchanged, no raise)",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.yaml")
    File.write!(path, "events: {}\n")

    Application.put_env(:lcars_fleet, :event_router_events_yaml_path, path)

    assert [] = Catalog.event_type_strings()
  end

  # JG-013 — VIDE ET ILLISIBLE SE RENDAIENT LE MEME `[]`, et le test ci-dessus n'epinglait que le
  # premier. Les deux lecteurs d'`events.yaml` traitaient la MEME faute differemment : `load!/0`
  # levait, `event_type_strings/0` se taisait. Le silence etait sans consequence sur le chemin
  # nominal — `load!/0` leve une ligne plus loin — et il ne l'etait PAS la ou le registre est coupe
  # volontairement (`event_router_load_event_registry: false`, la baseline hermetique) : la, `load!/0`
  # est un no-op, cette fonction est la SEULE source d'atomes pre-enregistres, et un fichier
  # illisible laissait la fleet sans aucun. La faute ressortait plus tard en `ArgumentError` sur un
  # `String.to_existing_atom/1` chez un consommateur — le message designait le consommateur, jamais
  # le fichier qu'on n'avait pas pu lire.
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
