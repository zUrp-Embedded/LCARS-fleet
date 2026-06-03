defmodule Fleet.Starfleet.Cat5EscalatorTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

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

  describe "escalate/2" do
    test "pod_drift : log + broadcast + coord backend invoqué", %{log_path: log_path} do
      payload = %{"pod_id" => "p1", "drift_count" => 3}

      assert :ok = Cat5Escalator.escalate(:pod_drift, payload)

      assert_receive {_atom,
                      %{
                        "event_type" => "audit.cat5.pod_drift",
                        "payload" => bcast_payload
                      }},
                     500

      assert bcast_payload["source"] == "pod_drift"
      assert bcast_payload["chain"] == ["starfleet.cat5.pod_drift"]
      assert bcast_payload["pod_id"] == "p1"

      [{:escalation, :pod_drift, ctx, _cid}] =
        Application.get_env(:fleet_starfleet, :coord_invocations)

      assert ctx["chain"] == ["starfleet.cat5.pod_drift"]

      content = File.read!(log_path)
      assert content =~ "cat5_escalate"
      assert content =~ "pod_drift"
    end

    test "chain préexistant étendu" do
      payload = %{"chain" => ["pod.refuse", "ipc_filter.drift"], "n" => 1}
      :ok = Cat5Escalator.escalate(:pipeline_failed, payload)

      assert_receive {_atom,
                      %{
                        "event_type" => "audit.cat5.pipeline_failed",
                        "payload" => %{"chain" => chain}
                      }},
                     500

      assert chain == ["pod.refuse", "ipc_filter.drift", "starfleet.cat5.pipeline_failed"]
    end

    test "oauth_refresh_failed : source string serialisé" do
      :ok = Cat5Escalator.escalate(:oauth_refresh_failed, %{"reason" => "401"})

      assert_receive {_atom,
                      %{
                        "event_type" => "audit.cat5.oauth_refresh_failed",
                        "payload" => %{"source" => "oauth_refresh_failed"}
                      }},
                     500
    end
  end
end
