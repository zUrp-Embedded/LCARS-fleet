defmodule Fleet.Starfleet.DriftMonitorTest do
  @moduledoc """
  Integration tests DriftMonitor → Bus events → Cat5Escalator → coord stub.

  PubSub Bus shared across tests: we filter by test-specific markers
  (`:coord_invocations` reset in setup, `:audit_log_path` per-test).

  BL-021: events are emitted with the canonical `%Fleet.Event{}` schema via
  `Bus.broadcast/2` (the legacy tuple format `Bus.broadcast/3` is no longer
  consumed by DriftMonitor — tuple handlers removed).
  """

  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.DriftMonitor

  # LOCAL name for the test instance (≠ the lib module's __MODULE__: no dependency left on an
  # app-booted global instance).
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

    # No app-booted instance (start_drift_monitor: false in test — suite hermeticity). This
    # INTEGRATION test starts its own, with a REAL subscribe (input goes through the Bus, that is
    # the point of the test); fixed local name (async: false justified: put_env).
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
    # Sync GenServer flush — ensures all previous handle_info messages
    # are consumed before the assertion.
    _ = :sys.get_state(@monitor)
    :ok
  end

  defp coord_invocations do
    Application.get_env(:fleet_starfleet, :coord_invocations, [])
  end

  # `source` defaults to `:event_router`. WIRED producers require their source (DriftMonitor
  # anti-spoof): workflow_map.failed / audit.verdict → `:workflow`; pod.drift → `:spawner` (F-C043).
  # Only oauth.refresh.failed remains type-only (dormant, no producer).
  defp emit_canon(type, payload, opts \\ []) do
    Bus.broadcast(
      "fleet.events",
      Fleet.Event.new(Keyword.get(opts, :source, :event_router), type,
        pod_id: opts[:pod_id],
        correlation_id: opts[:cid],
        payload: payload
      )
    )
  end

  describe "pod.drift event (source :spawner, F-C043)" do
    test "source :spawner + drift_count >= 3 → Cat5 escalation" do
      :ok =
        emit_canon(:"pod.drift", %{"pod_id" => "drifty", "drift_count" => 3},
          cid: "cid-1",
          pod_id: "drifty",
          source: :spawner
        )

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

    test "source :spawner + drift_count < 3 → no escalation" do
      :ok =
        emit_canon(:"pod.drift", %{"pod_id" => "early", "drift_count" => 2}, source: :spawner)

      wait_drift_monitor_drain()

      refute Enum.any?(coord_invocations(), fn
               {:escalation, :pod_drift, _, _} -> true
               _ -> false
             end)
    end

    test "anti-spoof: pod.drift with drift_count 3 but source ≠ :spawner (spoof) → NO escalation" do
      # F-C043: the handler requires `source: :spawner` (the producer = PermanentBoot). A pod.drift
      # broadcast under another source (spoof) CANNOT trigger the Cat 5.
      :ok =
        emit_canon(:"pod.drift", %{"pod_id" => "spoof", "drift_count" => 3},
          source: :event_router
        )

      wait_drift_monitor_drain()

      refute Enum.any?(coord_invocations(), fn
               {:escalation, :pod_drift, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "workflow_map.failed event" do
    test "source :workflow → Cat5 escalation workflow_map_failed" do
      :ok =
        emit_canon(:"workflow_map.failed", %{"workflow_map_id" => "pl1", "reason" => "gate fail"},
          source: :workflow
        )

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

    test "ANTI-SPOOF: same type but source ≠ :workflow → IGNORED (no escalation)" do
      # DriftMonitor invariant: a workflow_map.failed event emitted by a SPOOFED source
      # (here :event_router, e.g. a malicious pod) MUST NOT trigger the Cat-5 escalation.
      :ok =
        emit_canon(:"workflow_map.failed", %{"workflow_map_id" => "spoof"}, source: :event_router)

      wait_drift_monitor_drain()

      refute Enum.any?(coord_invocations(), fn
               {:escalation, :workflow_map_failed, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "oauth.refresh.failed event" do
    test "broadcast → Cat5 escalation oauth_refresh_failed" do
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
    test "source :workflow + valid decision_json → CoordBackend.handle_decision invoked" do
      json = ~s|{"decision":"halt","reason":"gatekeeper-said","details":{}}|

      :ok = emit_canon(:"audit.verdict", %{"decision_json" => json}, source: :workflow)

      wait_drift_monitor_drain()

      assert Enum.any?(coord_invocations(), fn
               {:decision, %{decision: "halt", reason: "gatekeeper-said"}, _} -> true
               _ -> false
             end)
    end

    test "ANTI-SPOOF: audit.verdict with source ≠ :workflow → IGNORED (no handle_decision)" do
      json = ~s|{"decision":"halt","reason":"spoofed","details":{}}|

      :ok = emit_canon(:"audit.verdict", %{"decision_json" => json}, source: :event_router)

      wait_drift_monitor_drain()

      refute Enum.any?(coord_invocations(), fn
               {:decision, _, _} -> true
               _ -> false
             end)
    end

    test "source :workflow + invalid decision_json → AuditLog write + no handle_decision",
         %{tmp_dir: tmp_dir} do
      :ok = emit_canon(:"audit.verdict", %{"decision_json" => ~s|{not json}|}, source: :workflow)

      wait_drift_monitor_drain()

      log_content = File.read!(Path.join(tmp_dir, "drift-monitor-test.jsonl"))
      assert log_content =~ "invalid_decision"

      refute Enum.any?(coord_invocations(), fn
               {:decision, _, _} -> true
               _ -> false
             end)
    end
  end

  describe "irrelevant events" do
    test "unknown event → ignored (no crash)" do
      :ok = emit_canon(:"pod.allocate", %{"pod_id" => "p1"})
      wait_drift_monitor_drain()

      # DriftMonitor still alive
      assert Process.alive?(Process.whereis(@monitor))
    end
  end
end
