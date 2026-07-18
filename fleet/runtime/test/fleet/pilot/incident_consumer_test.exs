defmodule Fleet.Pilot.IncidentConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.IncidentConsumer

  # subscribe: false (no stray Bus) + default runner (nil → SYNC, deterministic) + injected
  # record_fun (zero forge) that echoes the call back to the test. We verify the ROUTING event →
  # contract `record_or_escalate(op, subject, reason, opts)`, not the escalation policy (tested on
  # the registry side).
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

  test "pod.failed → record_or_escalate(\"pod\", pod_id, reason, reason_detail threaded)" do
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"pod.failed", %{
        "pod_id" => "pod_1",
        "reason" => "result_timeout",
        "reason_detail" => "{:result_timeout, \"pod_1\"}"
      })
    )

    # `reason` = stable category (key of the dedup signature); the full detail travels as an opt
    # down to the issue body (Escalation.detail_block) without polluting the signature.
    assert_receive {:rec, "pod", "pod_1", "result_timeout", opts}
    assert Keyword.get(opts, :reason_detail) == "{:result_timeout, \"pod_1\"}"
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
    # Payload without reason_detail (pre-normalization producer or forged event) → nil, never a crash.
    assert Keyword.get(opts, :reason_detail) == nil
  end

  test "failure event without pod_id → ignored (no record)" do
    me = self()
    pid = start(fn _, _, _, _ -> send(me, :rec) && :recorded end)

    send(pid, failed_event(:"pod.failed", %{"reason" => "boom"}))

    refute_receive :rec, 100
  end

  test "out-of-scope event (other type) → ignored" do
    me = self()
    pid = start(fn _, _, _, _ -> send(me, :rec) && :recorded end)

    send(pid, failed_event(:"pod.completed", %{"pod_id" => "pod_3"}))

    refute_receive :rec, 100
  end

  test "spawn.failed → record_or_escalate(\"spawn\", cap_profile_name, reason, opts)" do
    # The rail was ORPHANED (produced by PublishConsumer, never consumed): the 202 of
    # POST /api/admin/spawn lied silently when the dispatch dropped the spawn. Subject =
    # cap_profile_name (the role): recurrence groups "this role fails to spawn" (issue_id is
    # per-request → would never recur).
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"spawn.failed", %{
        "cap_profile_name" => "reviewer",
        "issue_id" => "issue_42",
        "reason" => "boom"
      })
    )

    assert_receive {:rec, "spawn", "reviewer", "boom", opts}
    assert Keyword.get(opts, :reason_detail) == nil
  end

  test "spawn.failed without cap_profile_name → ignored (guard)" do
    me = self()
    pid = start(fn _, _, _, _ -> send(me, :rec) && :recorded end)

    send(pid, failed_event(:"spawn.failed", %{"reason" => "boom"}))

    refute_receive :rec, 100
  end

  # ── Regression acte4 A-06 — durable Cat-5 ────────────────────────────────
  # A Cat-5 escalation (MAX severity — corrupted permanent seed, unreadable workflow_map) leaving
  # only a local NDJSON + 2 lossy Bus broadcasts EVAPORATES if nobody tails, while the
  # low-severity incident rail does open a durable forge issue (severity/durability inversion).
  # Instead: consumer → IncidentRegistry.escalate/5 DIRECT (issue from the 1st occurrence, label
  # error_cat5 — no recurrence gate), the correlation_id linking the issue to the causing mandate.

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

  test "A-06: cat5 pod_drift → escalate(:cat5) DIRECT, label error_cat5, correlation_id linked" do
    pid = start_cat5(cat5_echo())

    send(
      pid,
      Fleet.Event.new(:starfleet, :"starfleet.audit_cat5_pod_drift",
        pod_id: "permanent-architect",
        correlation_id: "issue-42",
        payload: %{"pod_id" => "permanent-architect", "reason" => "corrupted seed"}
      )
    )

    assert_receive {:esc, :cat5, "permanent-architect", "corrupted seed", sig, opts}
    assert sig == "cat5:pod_drift:permanent-architect"
    assert Keyword.get(opts, :label) == "error_cat5"
    assert Keyword.get(opts, :correlation_id) == "issue-42"
  end

  test "A-06: cat5 workflow_map_failed without pod_id → subject = the source (never a crash)" do
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

  test "A-06: cat5 escalation failure → LOUD (Logger.error), the consumer survives" do
    pid = start_cat5(fn _, _, _, _, _ -> {:error, :forge_down} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(
          pid,
          Fleet.Event.new(:starfleet, :"starfleet.audit_cat5_oauth_refresh_failed",
            payload: %{"reason" => "refresh KO"}
          )
        )

        # synchronize: the handle_info is processed before the call returns
        _ = :sys.get_state(pid)
      end)

    assert log =~ "Cat-5"
    assert log =~ "escalation FAILED"
    assert Process.alive?(pid)
  end
end
