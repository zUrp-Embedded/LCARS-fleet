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

  # JG-012 — LE MIROIR DU CONTROLE `cat5`, ET IL COURT DANS L'AUTRE SENS. `cat5` SYNTHETISE le type
  # `starfleet.audit_cat5_<cat5_source>` et le controle prouve que cette cle est enregistree.
  # `incident_cat5` CONSOMME le meme nommage : `IncidentConsumer.cat5_tag/1` derive le tag en
  # retirant le prefixe `starfleet.audit_cat5_` du type lui-meme. Or `String.replace_prefix/3` est
  # un NO-OP quand le prefixe est absent — une route `incident_cat5` sur un autre type n'echouait
  # pas, elle escaladait a severite MAXIMALE sous un tag egal au nom complet du type.
  #
  # La regle etait ecrite DEUX FOIS — dans le schema JSON du registre et dans le moduledoc
  # d'`IncidentConsumer` — et tenue par rien. Deux enonces en prose d'une contrainte ne font pas une
  # contrainte.
  #
  # ⚠ Ce n'est PAS le bloc de completude que la fiche demande : une route `incident_cat5` n'admet
  # que `{source, action, threshold?}` (schema `additionalProperties: false` + les deux controles
  # inverses). Il n'y a aucun bloc requis a omettre — ce qui peut etre malforme, c'est son NOM.
  @tag :tmp_dir
  test "JG-012: incident_cat5 sur un type sans le prefixe audit_cat5_ → boot REFUSE", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "events.yaml")

    File.write!(path, """
    events:
      pilot.step_stalled:
        source: pilot
        action: incident_cat5
    """)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert_raise RuntimeError, ~r/maximum severity under the tag/, fn ->
      Fleet.EventRouter.Catalog.load!()
    end
  end

  # LE TEMOIN. Sans lui, refuser TOUT `incident_cat5` rendrait le test ci-dessus vert pour la
  # mauvaise raison — et casserait les deux entrees livrees.
  @tag :tmp_dir
  test "JG-012 INVERSE — incident_cat5 sur un type correctement nomme passe", %{tmp_dir: tmp} do
    path = Path.join(tmp, "events.yaml")

    File.write!(path, """
    events:
      starfleet.audit_cat5_pod_drift:
        source: starfleet
        action: incident_cat5
    """)

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :event_router_events_yaml_path, path)
    Application.put_env(:lcars_fleet, :event_router_load_event_registry, true)
    on_exit(fn -> Application.put_env(:lcars_fleet, :event_router_load_event_registry, false) end)

    assert :ok = Fleet.EventRouter.Catalog.load!()

    assert %{action: :incident_cat5} =
             Fleet.EventRouter.Bus.event_routing()[
               {:starfleet, :"starfleet.audit_cat5_pod_drift"}
             ]
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
