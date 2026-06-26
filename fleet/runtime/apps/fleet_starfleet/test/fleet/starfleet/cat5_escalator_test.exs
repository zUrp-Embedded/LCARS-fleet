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
    test "pod_drift : log + broadcast canon + coord backend invoqué", %{log_path: log_path} do
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

    test "chain préexistant étendu" do
      payload = %{"chain" => ["pod.refuse", "ipc_filter.drift"], "n" => 1}
      :ok = Cat5Escalator.escalate(:pipeline_failed, payload, nil)

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"starfleet.audit_cat5_pipeline_failed",
                       payload: %{"chain" => chain}
                     },
                     500

      assert chain == ["pod.refuse", "ipc_filter.drift", "starfleet.cat5.pipeline_failed"]
    end

    test "oauth_refresh_failed : source string serialisé" do
      :ok = Cat5Escalator.escalate(:oauth_refresh_failed, %{"reason" => "401"}, nil)

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"starfleet.audit_cat5_oauth_refresh_failed",
                       payload: %{"source" => "oauth_refresh_failed"}
                     },
                     500
    end

    test "source dont l'atome canon n'est pas préregistré : escalade NON broadcastée mais LOUD (pas de :ok muet)" do
      # `starfleet.audit_cat5_bogus_cat5_src` n'a jamais été préregistré → le
      # `String.to_existing_atom/1` de `broadcast_canon` lève ArgumentError. C'est un
      # bug de construction de l'event, pas un boot-order : le rescue ne l'avale plus en
      # silence, il l'émet en Logger.error (sinon une escalade Cat-5 disparaîtrait muette).
      # `escalate/3` reste :ok (contrat fail-safe), mais AUCUN event canon ne part sur le bus.
      log =
        capture_log(fn ->
          assert :ok = Cat5Escalator.escalate(:bogus_cat5_src, %{"pod_id" => "p1"}, "cid-x")
        end)

      assert log =~ "escalade Cat-5 NON broadcastée"
      assert log =~ "event malformé"
      refute_receive %Fleet.Event{source: :starfleet}, 200
    end
  end
end
