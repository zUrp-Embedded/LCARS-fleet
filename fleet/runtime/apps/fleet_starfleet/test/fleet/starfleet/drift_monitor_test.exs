defmodule Fleet.Starfleet.DriftMonitorTest do
  @moduledoc """
  Tests intégration DriftMonitor → events Bus → Cat5Escalator → coord stub.

  Bus PubSub partagé entre tests : on filtre par marqueurs spécifiques
  (`:coord_invocations` reset en setup, `:audit_log_path` per-test).

  BL-021 chantier 3 : les events sont émis au schema canon `%Fleet.Event{}` via
  `Bus.broadcast/2` (le legacy tuple format `Bus.broadcast/3` n'est plus consommé
  par DriftMonitor — handlers tuple retirés).
  """

  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.DriftMonitor

  # Nom LOCAL de l'instance de test (≠ __MODULE__ du module lib : plus aucune dépendance à une
  # instance globale app-bootée).
  @monitor __MODULE__.Monitor

  setup %{tmp_dir: tmp_dir} do
    log_path = Path.join(tmp_dir, "drift-monitor-test.jsonl")
    Application.put_env(:fleet_starfleet, :audit_log_path, log_path)

    Application.put_env(
      :fleet_starfleet,
      :coord_backend,
      Fleet.Starfleet.CoordBackendStub
    )

    Application.put_env(:fleet_starfleet, :coord_invocations, [])

    # Conformité 2026-07-04 : plus d'instance app-bootée (start_drift_monitor: false en test —
    # hermétisme de la suite). Ce test d'INTÉGRATION démarre la sienne, subscribe RÉEL (l'entrée
    # passe par le Bus, c'est l'objet du test) ; nom local fixe (async: false justifié : put_env).
    monitor = start_supervised!({DriftMonitor, name: @monitor})

    Bus.subscribe()

    on_exit(fn ->
      Application.delete_env(:fleet_starfleet, :audit_log_path)
      Application.delete_env(:fleet_starfleet, :coord_backend)
      Application.delete_env(:fleet_starfleet, :coord_invocations)
    end)

    %{monitor: monitor}
  end

  defp wait_drift_monitor_drain do
    # Sync GenServer flush — assure que tous les handle_info précédents
    # sont consommés avant l'assertion.
    _ = :sys.get_state(@monitor)
    :ok
  end

  defp coord_invocations do
    Application.get_env(:fleet_starfleet, :coord_invocations, [])
  end

  defp emit_canon(type, payload, cid \\ nil, pod_id \\ nil) do
    Bus.broadcast(
      "fleet.events",
      Fleet.Event.new(:event_router, type, pod_id: pod_id, correlation_id: cid, payload: payload)
    )
  end

  describe "pod.drift event" do
    test "drift_count >= 3 → Cat5 escalade" do
      :ok =
        emit_canon(:"pod.drift", %{"pod_id" => "drifty", "drift_count" => 3}, "cid-1", "drifty")

      wait_drift_monitor_drain()

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"starfleet.audit_cat5_pod_drift",
                       payload: %{"pod_id" => "drifty"}
                     },
                     500

      assert Enum.any?(coord_invocations(), fn
               {:escalation, :pod_drift, _, _} -> true
               _ -> false
             end)
    end

    test "drift_count < 3 → no escalade" do
      :ok = emit_canon(:"pod.drift", %{"pod_id" => "early", "drift_count" => 2})

      wait_drift_monitor_drain()

      refute Enum.any?(coord_invocations(), fn
               {:escalation, :pod_drift, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "workflow_map.failed event" do
    test "broadcast → Cat5 escalade workflow_map_failed" do
      :ok =
        emit_canon(:"workflow_map.failed", %{"workflow_map_id" => "pl1", "reason" => "gate fail"})

      wait_drift_monitor_drain()

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"starfleet.audit_cat5_workflow_map_failed",
                       payload: %{"workflow_map_id" => "pl1"}
                     },
                     500

      assert Enum.any?(coord_invocations(), fn
               {:escalation, :workflow_map_failed, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "oauth.refresh.failed event" do
    test "broadcast → Cat5 escalade oauth_refresh_failed" do
      :ok =
        emit_canon(:"oauth.refresh.failed", %{
          "account" => "u@x.com",
          "lead_time_min" => 30
        })

      wait_drift_monitor_drain()

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"starfleet.audit_cat5_oauth_refresh_failed",
                       payload: %{"account" => "u@x.com"}
                     },
                     500

      assert Enum.any?(coord_invocations(), fn
               {:escalation, :oauth_refresh_failed, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "audit.verdict event" do
    test "decision_json valide → CoordBackend.handle_decision invoqué" do
      json = ~s|{"decision":"halt","reason":"gatekeeper-said","details":{}}|

      :ok = emit_canon(:"audit.verdict", %{"decision_json" => json})

      wait_drift_monitor_drain()

      assert Enum.any?(coord_invocations(), fn
               {:decision, %{decision: "halt", reason: "gatekeeper-said"}, _} -> true
               _ -> false
             end)
    end

    test "decision_json invalide → AuditLog write + pas de handle_decision",
         %{tmp_dir: tmp_dir} do
      :ok = emit_canon(:"audit.verdict", %{"decision_json" => ~s|{not json}|})

      wait_drift_monitor_drain()

      log_content = File.read!(Path.join(tmp_dir, "drift-monitor-test.jsonl"))
      assert log_content =~ "invalid_decision"

      refute Enum.any?(coord_invocations(), fn
               {:decision, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "events non-pertinents" do
    test "event inconnu → ignoré (no crash)" do
      :ok = emit_canon(:"pod.allocate", %{"pod_id" => "p1"})
      wait_drift_monitor_drain()

      # DriftMonitor toujours vivant
      assert Process.alive?(Process.whereis(@monitor))
    end
  end
end
