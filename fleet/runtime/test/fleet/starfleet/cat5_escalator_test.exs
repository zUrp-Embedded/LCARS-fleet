defmodule Fleet.Starfleet.Cat5EscalatorTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.Cat5Escalator

  setup %{tmp_dir: tmp_dir} do
    log_path = Path.join(tmp_dir, "test-starfleet.jsonl")
    Application.put_env(:fleet_starfleet, :audit_log_path, log_path)

    Application.put_env(
      :fleet_starfleet,
      :coord_backend,
      Fleet.Starfleet.CoordBackendStub
    )

    Application.put_env(:fleet_starfleet, :coord_invocations, [])

    Bus.subscribe()

    on_exit(fn ->
      Application.delete_env(:fleet_starfleet, :audit_log_path)
      Application.delete_env(:fleet_starfleet, :coord_backend)
      Application.delete_env(:fleet_starfleet, :coord_invocations)
    end)

    {:ok, log_path: log_path}
  end

  describe "escalate/3" do
    test "pod_drift: log + canonical broadcast + coord backend invoked", %{log_path: log_path} do
      payload = %{"pod_id" => "p1", "drift_count" => 3}
      cid = "corr-1"

      assert :ok = Cat5Escalator.escalate(:pod_drift, payload, cid)

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"starfleet.audit_cat5_pod_drift",
                       correlation_id: ^cid,
                       pod_id: "p1",
                       payload: bcast_payload
                     },
                     500

      assert bcast_payload["source"] == "pod_drift"
      assert bcast_payload["chain"] == ["starfleet.cat5.pod_drift"]
      assert bcast_payload["pod_id"] == "p1"

      [{:escalation, :pod_drift, ctx, ^cid}] =
        Application.get_env(:fleet_starfleet, :coord_invocations)

      assert ctx["chain"] == ["starfleet.cat5.pod_drift"]

      content = File.read!(log_path)
      assert content =~ "cat5_escalate"
      assert content =~ "pod_drift"
    end

    test "pre-existing chain is extended" do
      payload = %{"chain" => ["pod.refuse", "ipc_filter.drift"], "n" => 1}
      :ok = Cat5Escalator.escalate(:workflow_map_failed, payload, nil)

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"starfleet.audit_cat5_workflow_map_failed",
                       payload: %{"chain" => chain}
                     },
                     500

      assert chain == ["pod.refuse", "ipc_filter.drift", "starfleet.cat5.workflow_map_failed"]
    end

    test "oauth_refresh_failed: source serialized as string" do
      :ok = Cat5Escalator.escalate(:oauth_refresh_failed, %{"reason" => "401"}, nil)

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"starfleet.audit_cat5_oauth_refresh_failed",
                       payload: %{"source" => "oauth_refresh_failed"}
                     },
                     500
    end

    test "R2-15: source OUTSIDE the Cat 5 enum → loud REFUSAL (error) + :ok, NO broadcast/effect" do
      # `:bogus_cat5_src` is not one of the 3 wired sources (DriftMonitor + events.yaml). R2-15 bounds
      # `escalate` to the source-enum: an unknown atom must not proceed to broadcasting an unregistered
      # `audit_cat5_<src>` (event-construction bug, loud only at broadcast level). Refusal happens AT
      # THE EDGE (no bogus side effect: no AuditLog.write, no broadcast, no coord). `escalate/3` stays
      # :ok (fail-safe contract), but LOUD (Logger.error) — never a mute :ok.
      log =
        capture_log(fn ->
          assert :ok = Cat5Escalator.escalate(:bogus_cat5_src, %{"pod_id" => "p1"}, "cid-x")
        end)

      assert log =~ "REFUSED unknown Cat 5 source"
      refute_receive %Fleet.Event{source: :starfleet}, 200
    end
  end
end
