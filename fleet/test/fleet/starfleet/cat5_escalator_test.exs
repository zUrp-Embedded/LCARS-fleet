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
      {:workflow, :"audit.verdict"} => %{
        action: :coord_decision,
        cat5_source: nil,
        threshold: nil
      }
    })

    on_exit(fn -> Bus.set_event_routing(prior_routing) end)

    log_path = Path.join(tmp_dir, "test-starfleet.jsonl")
    Application.put_env(:lcars_fleet, :starfleet_audit_log_path, log_path)

    Application.put_env(
      :lcars_fleet,
      :starfleet_coord_backend,
      Fleet.Starfleet.CoordBackendStub
    )

    Application.put_env(:lcars_fleet, :starfleet_coord_invocations, [])

    Bus.subscribe()

    on_exit(fn ->
      Application.delete_env(:lcars_fleet, :starfleet_audit_log_path)
      Application.delete_env(:lcars_fleet, :starfleet_coord_backend)
      Application.delete_env(:lcars_fleet, :starfleet_coord_invocations)
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
        Application.get_env(:lcars_fleet, :starfleet_coord_invocations)

      assert ctx["chain"] == ["starfleet.cat5.pod_drift"]

      content = File.read!(log_path)
      assert content =~ "cat5_escalate"
      assert content =~ "pod_drift"
    end

    # JG-118 — L'ECRITURE D'AUDIT EST LA DERNIERE TRACE DURABLE D'UNE CAT-5, et son echec etait jete.
    # Tout ce qui suit est LOSSY par construction : `broadcast_canon/3` est un PubSub sans accuse, et
    # `CoordBackend.handle_escalation/3` ne fait qu'un second broadcast sur le meme bus. Si l'audit
    # echoue AUSSI, l'escalade de severite maximale n'existe NULLE PART — et l'appelant recoit `:ok`.
    #
    # `AuditLog.write/1` loggue deja son echec, mais sous son identite a lui : rien ne disait que la
    # ligne perdue etait une CAT-5, ni que plus aucun rail ne la portait.
    test "JG-118: audit d'une CAT-5 non gravable → la perte est nommee comme terminale", %{
      tmp_dir: tmp_dir
    } do
      # Le chemin d'audit devient un REPERTOIRE : `File.write` echoue (`:eisdir`), sans casser
      # `File.mkdir_p` du parent.
      broken = Path.join(tmp_dir, "audit-is-a-dir.jsonl")
      File.mkdir_p!(broken)
      Application.put_env(:lcars_fleet, :starfleet_audit_log_path, broken)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Cat5Escalator.escalate(:pod_drift, %{"pod_id" => "p9"}, "corr-jg118")
        end)

      assert log =~ "NO DURABLE TRACE",
             "l'echec de la derniere trace durable d'une Cat-5 ne dit pas ce qu'il est"

      assert log =~ "corr-jg118",
             "la trace ne porte pas le correlation_id : elle n'est pas suivable"

      assert log =~ "may exist NOWHERE",
             "rien ne dit que tout l'aval est lossy — un lecteur croira qu'un rail rattrape"
    end

    test "TEMOIN JG-118 — un audit qui s'ecrit ne declenche aucune alarme", %{log_path: log_path} do
      # Sans ce temoin, crier a chaque escalade passerait le test ci-dessus.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Cat5Escalator.escalate(:pod_drift, %{"pod_id" => "p8"}, "corr-ok")
        end)

      refute log =~ "NO DURABLE TRACE"
      assert File.read!(log_path) =~ "cat5_escalate"
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

    # The property is the SERIALIZATION (an atom source lands as a string in the payload), not the
    # source that carries it — this case rode on `oauth_refresh_failed` until that key was cut
    # (BL-6-43) and moved to `pod_drift` unchanged.
    test "source serialized as string" do
      :ok = Cat5Escalator.escalate(:pod_drift, %{"reason" => "401"}, nil)

      assert_receive %Fleet.Event{
                       source: :starfleet,
                       type: :"starfleet.audit_cat5_pod_drift",
                       payload: %{"source" => "pod_drift"}
                     },
                     500
    end

    test "R2-15: source OUTSIDE the Cat 5 enum → loud REFUSAL (error) + :ok, NO broadcast/effect" do
      # `:bogus_cat5_src` is not one of the 2 wired sources (DriftMonitor + events.yaml). R2-15 bounds
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
    Application.put_env(
      :lcars_fleet,
      :starfleet_coord_backend,
      Fleet.Starfleet.CoordBackendRaising
    )

    log_path = Application.get_env(:lcars_fleet, :starfleet_audit_log_path)

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
