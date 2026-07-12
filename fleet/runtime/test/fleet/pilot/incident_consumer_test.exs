defmodule Fleet.Pilot.IncidentConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.IncidentConsumer

  # subscribe: false (pas de Bus parasite) + runner défaut (nil → SYNC, déterministe) + record_fun
  # injecté (zéro forge) qui renvoie l'appel au test. On vérifie le ROUTAGE event → contrat
  # `record_or_escalate(op, subject, reason, opts)`, pas la politique d'escalade (testée côté registre).
  defp start(record_fun) do
    start_supervised!({IncidentConsumer, subscribe: false, record_fun: record_fun})
  end

  defp echo_fun do
    me = self()

    fn op, subject, reason, opts ->
      send(me, {:rec, op, subject, reason, opts})
      :recorded
    end
  end

  defp failed_event(type, payload),
    do: Fleet.Event.new(:spawner, type, payload: payload)

  test "pod.failed → record_or_escalate(\"pod\", pod_id, reason, [])" do
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"pod.failed", %{"pod_id" => "pod_1", "reason" => "result_timeout"})
    )

    assert_receive {:rec, "pod", "pod_1", "result_timeout", []}
  end

  test "wake.failed → record_or_escalate(\"wake\", …, escalate_kind: :sp_suspect, pane:)" do
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"wake.failed", %{
        "pod_id" => "pod_2",
        "reason" => "no_ack",
        "pane" => "sess:1.2"
      })
    )

    assert_receive {:rec, "wake", "pod_2", "no_ack", opts}
    assert Keyword.get(opts, :escalate_kind) == :sp_suspect
    assert Keyword.get(opts, :pane) == "sess:1.2"
  end

  test "event d'échec sans pod_id → ignoré (pas de record)" do
    me = self()
    pid = start(fn _, _, _, _ -> send(me, :rec) && :recorded end)

    send(pid, failed_event(:"pod.failed", %{"reason" => "boom"}))

    refute_receive :rec, 100
  end

  test "event hors-scope (autre type) → ignoré" do
    me = self()
    pid = start(fn _, _, _, _ -> send(me, :rec) && :recorded end)

    send(pid, failed_event(:"pod.completed", %{"pod_id" => "pod_3"}))

    refute_receive :rec, 100
  end

  test "spawn.failed → record_or_escalate(\"spawn\", cap_profile_name, reason, [])" do
    # Le rail était ORPHELIN (produit par PublishConsumer, jamais consommé) : le 202 de
    # POST /api/admin/spawn mentait en silence quand le dispatch droppait le spawn. Sujet =
    # cap_profile_name (le rôle) : la récurrence groupe « ce rôle échoue à spawner » (issue_id
    # est per-requête → ne récurrerait jamais).
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"spawn.failed", %{
        "cap_profile_name" => "reviewer",
        "issue_id" => "issue_42",
        "reason" => "boom"
      })
    )

    assert_receive {:rec, "spawn", "reviewer", "boom", []}
  end

  test "spawn.failed sans cap_profile_name → ignoré (garde)" do
    me = self()
    pid = start(fn _, _, _, _ -> send(me, :rec) && :recorded end)

    send(pid, failed_event(:"spawn.failed", %{"reason" => "boom"}))

    refute_receive :rec, 100
  end

  # ── Régression acte4 A-06 — Cat-5 durable ────────────────────────────────
  # AVANT : l'escalade Cat-5 (sévérité MAX — seed permanent corrompu, workflow_map illisible)
  # ne laissait qu'un NDJSON local + 2 broadcasts Bus lossy → ÉVAPORÉE si personne ne tail,
  # pendant que le rail incident basse-sévérité ouvrait, lui, une issue forge durable
  # (inversion sévérité/durabilité). APRÈS : consumer → IncidentRegistry.escalate/5 DIRECT
  # (issue dès la 1re occurrence, label error_cat5 — pas de gate de récurrence), le
  # correlation_id (vague E) reliant l'issue au mandat causant.

  defp start_cat5(escalate_fun) do
    start_supervised!(
      {IncidentConsumer,
       subscribe: false, record_fun: fn _, _, _, _ -> :recorded end, escalate_fun: escalate_fun}
    )
  end

  defp cat5_echo do
    me = self()

    fn kind, subject, reason, sig, opts ->
      send(me, {:esc, kind, subject, reason, sig, opts})
      {:ok, 77}
    end
  end

  test "A-06 : cat5 pod_drift → escalate(:cat5) DIRECT, label error_cat5, correlation_id lié" do
    pid = start_cat5(cat5_echo())

    send(
      pid,
      Fleet.Event.new(:starfleet, :"starfleet.audit_cat5_pod_drift",
        pod_id: "permanent-architect",
        correlation_id: "issue-42",
        payload: %{"pod_id" => "permanent-architect", "reason" => "seed corrompu"}
      )
    )

    assert_receive {:esc, :cat5, "permanent-architect", "seed corrompu", sig, opts}
    assert sig == "cat5:pod_drift:permanent-architect"
    assert Keyword.get(opts, :label) == "error_cat5"
    assert Keyword.get(opts, :correlation_id) == "issue-42"
  end

  test "A-06 : cat5 workflow_map_failed sans pod_id → subject = la source (jamais un crash)" do
    pid = start_cat5(cat5_echo())

    send(
      pid,
      Fleet.Event.new(:starfleet, :"starfleet.audit_cat5_workflow_map_failed",
        correlation_id: "issue-7",
        payload: %{"reason" => "load KO"}
      )
    )

    assert_receive {:esc, :cat5, "workflow_map_failed", "load KO", sig, _opts}
    assert sig == "cat5:workflow_map_failed:workflow_map_failed"
  end

  test "A-06 : échec d'escalade cat5 → LOUD (Logger.error), le consumer survit" do
    pid = start_cat5(fn _, _, _, _, _ -> {:error, :forge_down} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(
          pid,
          Fleet.Event.new(:starfleet, :"starfleet.audit_cat5_oauth_refresh_failed",
            payload: %{"reason" => "refresh KO"}
          )
        )

        # synchronise : le handle_info est traité avant le retour du call
        _ = :sys.get_state(pid)
      end)

    assert log =~ "Cat-5"
    assert log =~ "escalation FAILED"
    assert Process.alive?(pid)
  end
end
