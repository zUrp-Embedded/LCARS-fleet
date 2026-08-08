defmodule Fleet.Starfleet.CoordBackendRaising do
  @moduledoc false
  # Un backend de coordination qui EXPLOSE. Il n'existe que pour tenir l'ORDRE : c'est le seul
  # moyen de distinguer « l'audit est ecrit » de « l'audit est ecrit AVANT le routage », et
  # l'inversion des deux laissait 2438 tests verts.
  @behaviour Fleet.Starfleet.CoordBackend

  @impl true
  def handle_decision(_decision, _correlation_id), do: raise("coord backend down")

  @impl true
  def handle_escalation(_source, _payload, _correlation_id), do: raise("coord backend down")
end

defmodule Fleet.Starfleet.Cat5EscalatorTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.Cat5Escalator

  setup %{tmp_dir: tmp_dir} do
    # The Cat 5 source enum is DERIVED from the routing table (B-05) — set the canon-equivalent
    # cat5 tags explicitly (test env keeps the boot loader off).
    prior_routing = Bus.event_routing()

    Bus.set_event_routing(%{
      {:spawner, :"pod.drift"} => %{
        action: :cat5,
        cat5_source: :pod_drift,
        threshold: %{counter: "drift_count", min: 3}
      },
      {:workflow, :"workflow_map.failed"} => %{
        action: :cat5,
        cat5_source: :workflow_map_failed,
        threshold: nil
      },
      {:credentials, :"oauth.refresh.failed"} => %{
        action: :cat5,
        cat5_source: :oauth_refresh_failed,
        threshold: nil
      }
    })

    on_exit(fn -> Bus.set_event_routing(prior_routing) end)

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

  test "l'audit est ecrit AVANT le routage — un backend qui explose ne doit pas emporter la trace" do
    # LA DOCTRINE D1 EST UN ORDRE, PAS UN APPEL. « la trace durable est l'audit log, ecrit AVANT le
    # routage » : mesure du 2026-08-08, inverser les deux lignes laissait les 2438 tests verts.
    # Seul un backend qui LEVE distingue les deux mondes — avec un backend qui rend `:ok`, l'ordre
    # est inobservable et le test passerait dans les deux sens.
    Application.put_env(:fleet_starfleet, :coord_backend, Fleet.Starfleet.CoordBackendRaising)
    log_path = Application.get_env(:fleet_starfleet, :audit_log_path)

    assert_raise RuntimeError, "coord backend down", fn ->
      Cat5Escalator.escalate(:pod_drift, %{"drift_count" => 9}, "corr-order")
    end

    assert File.exists?(log_path),
           "le routage a explose et la trace a disparu avec lui — c'est exactement ce que " <>
             "l'ordre existe pour empecher"

    entry =
      log_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> List.last()
      |> JSON.decode!()

    assert entry["action"] == "cat5_escalate"
    assert entry["correlation_id"] == "corr-order"
  end
end
