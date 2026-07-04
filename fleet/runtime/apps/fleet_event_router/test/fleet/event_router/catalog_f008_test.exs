defmodule Fleet.EventRouter.CatalogF008Test do
  # async: false — mute la config globale :load_event_registry / :events_yaml_path.
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Catalog
  alias Fleet.EventRouter.TestEnv

  setup do
    # Les tests posent :load_event_registry / :events_yaml_path eux-mêmes ; capture-restauration seule.
    TestEnv.restore_env_on_exit(:fleet_event_router, :load_event_registry)
    TestEnv.restore_env_on_exit(:fleet_event_router, :events_yaml_path)
    :ok
  end

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

  # Trou fail-open jumeau de F-008 : un events.yaml VALIDE mais VIDE (`events: {}`) parse OK
  # (`{:ok, %{}}`) → l'ancien `do_load` posait un MapSet vide → le Bus (permissif sur registry vide
  # par défaut) broadcastait TOUT type sans validation, boot « vert » mais registry mort. En régime
  # réel (`load_event_registry: true`) `do_load` doit désormais raise comme pour un fichier absent.
  @tag :tmp_dir
  test "events.yaml VIDE (events: {}) + registry voulu (prod) → raise (fail-open registry-vide fermé)",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.yaml")
    File.write!(path, "events: {}\n")

    Application.put_env(:fleet_event_router, :load_event_registry, true)
    Application.put_env(:fleet_event_router, :events_yaml_path, path)

    assert_raise RuntimeError, ~r/events\.yaml VIDE/, fn ->
      Catalog.load!()
    end
  end

  # Non-régression de l'AUTRE lecteur du parse : `event_type_strings/0` (source de
  # `preregister_event_atoms/0`) doit toujours rendre `[]` sur un events.yaml vide — il n'a rien à
  # pré-enregistrer et NE doit PAS fail-loud (sinon `Application.preregister_event_atoms/0` casserait).
  @tag :tmp_dir
  test "event_type_strings/0 rend [] sur events.yaml VIDE (preregister inchangé, pas de raise)",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "events.yaml")
    File.write!(path, "events: {}\n")

    Application.put_env(:fleet_event_router, :events_yaml_path, path)

    assert [] = Catalog.event_type_strings()
  end
end
