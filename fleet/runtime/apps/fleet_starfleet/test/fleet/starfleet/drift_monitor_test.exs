defmodule Fleet.Starfleet.DriftMonitorTest do
  @moduledoc """
  Tests intégration DriftMonitor → events Bus → Cat5Escalator → coord stub.

  Bus PubSub partagé entre tests : on filtre par marqueurs spécifiques
  (`:coord_invocations` reset en setup, `:audit_log_path` per-test).
  """

  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.DriftMonitor

  setup %{tmp_dir: tmp_dir} do
    log_path = Path.join(tmp_dir, "drift-monitor-test.jsonl")
    Application.put_env(:fleet_starfleet, :audit_log_path, log_path)

    Application.put_env(
      :fleet_starfleet,
      :coord_backend,
      Fleet.Starfleet.CoordBackendStub
    )

    Application.put_env(:fleet_starfleet, :coord_invocations, [])

    # Application supervisor démarre déjà le DriftMonitor — on le subscribe
    # au Bus en init. Pas besoin de start_supervised.
    Bus.subscribe()

    on_exit(fn ->
      Application.delete_env(:fleet_starfleet, :audit_log_path)
      Application.delete_env(:fleet_starfleet, :coord_backend)
      Application.delete_env(:fleet_starfleet, :coord_invocations)
    end)

    :ok
  end

  defp wait_drift_monitor_drain do
    # Sync GenServer flush — assure que tous les handle_info précédents
    # sont consommés avant l'assertion.
    _ = :sys.get_state(DriftMonitor)
    :ok
  end

  defp coord_invocations do
    Application.get_env(:fleet_starfleet, :coord_invocations, [])
  end

  describe "pod_drift event" do
    test "drift_count >= 3 → Cat5 escalade" do
      :ok = Bus.broadcast("pod_drift", %{"pod_id" => "drifty", "drift_count" => 3}, [])

      wait_drift_monitor_drain()

      assert_receive {_atom,
                      %{
                        "event_type" => "audit.cat5.pod_drift",
                        "payload" => %{"pod_id" => "drifty"}
                      }},
                     500

      assert Enum.any?(coord_invocations(), fn
               {:escalation, :pod_drift, _} -> true
               _ -> false
             end)
    end

    test "drift_count < 3 → no escalade" do
      :ok = Bus.broadcast("pod_drift", %{"pod_id" => "early", "drift_count" => 2}, [])

      wait_drift_monitor_drain()

      refute Enum.any?(coord_invocations(), fn
               {:escalation, :pod_drift, _} -> true
               _ -> false
             end)
    end
  end

  describe "pipeline.failed event" do
    test "broadcast → Cat5 escalade pipeline_failed" do
      :ok =
        Bus.broadcast(
          "pipeline.failed",
          %{"pipeline_id" => "pl1", "reason" => "gate fail"},
          []
        )

      wait_drift_monitor_drain()

      assert_receive {_atom,
                      %{
                        "event_type" => "audit.cat5.pipeline_failed",
                        "payload" => %{"pipeline_id" => "pl1"}
                      }},
                     500

      assert Enum.any?(coord_invocations(), fn
               {:escalation, :pipeline_failed, _} -> true
               _ -> false
             end)
    end
  end

  describe "oauth.refresh.failed event" do
    test "broadcast → Cat5 escalade oauth_refresh_failed" do
      :ok =
        Bus.broadcast(
          "oauth.refresh.failed",
          %{"account" => "u@x.com", "lead_time_min" => 30},
          []
        )

      wait_drift_monitor_drain()

      assert_receive {_atom,
                      %{
                        "event_type" => "audit.cat5.oauth_refresh_failed",
                        "payload" => %{"account" => "u@x.com"}
                      }},
                     500

      assert Enum.any?(coord_invocations(), fn
               {:escalation, :oauth_refresh_failed, _} -> true
               _ -> false
             end)
    end
  end

  describe "audit.verdict event" do
    test "decision_json valide → CoordBackend.handle_decision invoqué" do
      json = ~s|{"decision":"halt","reason":"gatekeeper-said","details":{}}|

      :ok = Bus.broadcast("audit.verdict", %{"decision_json" => json}, [])

      wait_drift_monitor_drain()

      assert Enum.any?(coord_invocations(), fn
               {:decision, %{decision: "halt", reason: "gatekeeper-said"}} -> true
               _ -> false
             end)
    end

    test "decision_json invalide → AuditLog write + pas de handle_decision",
         %{tmp_dir: tmp_dir} do
      :ok = Bus.broadcast("audit.verdict", %{"decision_json" => ~s|{not json}|}, [])

      wait_drift_monitor_drain()

      log_content = File.read!(Path.join(tmp_dir, "drift-monitor-test.jsonl"))
      assert log_content =~ "invalid_decision"

      refute Enum.any?(coord_invocations(), fn
               {:decision, _} -> true
               _ -> false
             end)
    end
  end

  describe "events non-pertinents" do
    test "event inconnu → ignoré (no crash)" do
      :ok = Bus.broadcast("pod.allocate", %{"pod_id" => "p1"}, [])
      wait_drift_monitor_drain()

      # DriftMonitor toujours vivant
      assert Process.alive?(Process.whereis(DriftMonitor))
    end
  end
end
