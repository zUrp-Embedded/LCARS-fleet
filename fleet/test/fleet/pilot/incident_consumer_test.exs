defmodule Fleet.Pilot.IncidentConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.IncidentConsumer

  # subscribe: false (no stray Bus) + default runner (nil → SYNC, deterministic) + injected
  # record_fun (zero forge) that echoes the call back to the test. We verify the ROUTING event →
  # contract `record_or_escalate(op, subject, reason, opts)`, not the escalation policy (tested on
  # the registry side).
  # Canon-equivalent classification table via the `:routing_fun` seam (the consumer is a MECHANIC
  # over the table — audit B-05); hermetic (no global persistent_term mutation, async stays true).
  defp routing do
    %{
      {:spawner, :"pod.failed"} => %{
        action: :incident,
        incident: %{op: "pod", subject: "pod_id", escalate_kind: nil, forward: []}
      },
      {:spawner, :"wake.failed"} => %{
        action: :incident,
        incident: %{op: "wake", subject: "pod_id", escalate_kind: :sp_suspect, forward: [:pane]}
      },
      {:spawner, :"spawn.failed"} => %{
        action: :incident,
        incident: %{op: "spawn", subject: "cap_profile_name", escalate_kind: nil, forward: []}
      },
      {:starfleet, :"starfleet.audit_cat5_pod_drift"} => %{action: :incident_cat5},
      {:starfleet, :"starfleet.audit_cat5_workflow_map_failed"} => %{action: :incident_cat5}
    }
  end

  defp start(record_fun, opts \\ []) do
    start_supervised!(
      {IncidentConsumer,
       [subscribe: false, record_fun: record_fun, routing_fun: fn -> routing() end] ++ opts}
    )
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

  describe "LE FREIN (BL-6-37.6) — detecter la recurrence sans debrancher fabriquait un compteur" do
    defp brake_spy do
      me = self()
      fn repo, number, reason -> send(me, {:brake, repo, number, reason}) end
    end

    defp brake_event(payload),
      do: failed_event(:"pod.failed", Map.merge(%{"pod_id" => "pod_1"}, payload))

    defp start_with(outcome, extra \\ []) do
      start(fn _op, _s, _r, _o -> outcome end, [brake_fun: brake_spy()] ++ extra)
    end

    test "recurrence ESCALADEE sur un result_timeout → le ticket sort du dispatch" do
      pid = start_with({:escalated, 77})

      send(
        pid,
        brake_event(%{
          "repo" => "fleet/demo",
          "issue_id" => "issue-42",
          "reason" => "result_timeout"
        })
      )

      assert_receive {:brake, "fleet/demo", 42, "result_timeout"}, 500
    end

    test "recurrence SOUS COOLDOWN → le frein s'applique AUSSI (c'est la que vit la boucle)" do
      # LE cas qui discrimine. La suppression concerne l'ISSUE SYSADMIN — ne pas en ouvrir une par
      # tick — pas la boucle de re-dispatch. Ne freiner que sur `{:escalated, _}` laisserait le
      # ticket repartir a l'infini des la deuxieme recurrence, c'est-a-dire l'incident mesure.
      pid = start_with({:escalation_suppressed, 77})

      send(
        pid,
        brake_event(%{
          "repo" => "fleet/demo",
          "issue_id" => "issue-42",
          "reason" => "result_timeout"
        })
      )

      assert_receive {:brake, "fleet/demo", 42, _}, 500
    end

    test "PREMIERE occurrence → AUCUN frein (une panne isolee peut etre du hasard)" do
      pid = start_with(:recorded)

      send(
        pid,
        brake_event(%{
          "repo" => "fleet/demo",
          "issue_id" => "issue-42",
          "reason" => "result_timeout"
        })
      )

      refute_receive {:brake, _, _, _}, 200
    end

    test "recurrence sur une AUTRE categorie → aucun frein (restriction deliberee)" do
      # Un `exited_before_result` peut etre une erreur de brief qu'un rework corrige. Elargir le
      # frein se fera sur une mesure, pas sur une intuition.
      pid = start_with({:escalated, 77})

      send(
        pid,
        brake_event(%{
          "repo" => "fleet/demo",
          "issue_id" => "issue-42",
          "reason" => "exited_before_result"
        })
      )

      refute_receive {:brake, _, _, _}, 200
    end

    test "payload SANS depot → aucun frein, et aucun crash du rail d'incident" do
      # `issue_id` vaut `issue-<n>` : un numero sans depot ne designe rien d'ecrivable. Le rail
      # d'incident est le rail de derniere instance — il degrade, il ne tombe pas.
      pid = start_with({:escalated, 77})

      send(pid, brake_event(%{"issue_id" => "issue-42", "reason" => "result_timeout"}))

      refute_receive {:brake, _, _, _}, 200
      assert Process.alive?(pid)
    end
  end

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

  test "the classification is DATA: re-declaring the op in the table changes the recording, zero code" do
    # The killer discriminator vs hardcoded clauses: the SAME wake.failed event records under the
    # op the TABLE declares — the old handler carried "wake" in code and could not follow.
    me = self()

    fun = fn op, subject, reason, opts ->
      send(me, {:rec, op, subject, reason, opts})
      :recorded
    end

    pid =
      start_supervised!(
        {IncidentConsumer,
         subscribe: false,
         record_fun: fun,
         routing_fun: fn ->
           %{
             {:spawner, :"wake.failed"} => %{
               action: :incident,
               incident: %{op: "reveil", subject: "pod_id", escalate_kind: nil, forward: []}
             }
           }
         end}
      )

    send(pid, failed_event(:"wake.failed", %{"pod_id" => "pod_9", "reason" => "no_ack"}))
    assert_receive {:rec, "reveil", "pod_9", "no_ack", _opts}
  end

  test "a routed incident whose subject key is MISSING → LOUD producer-bug warning, nothing recorded" do
    me = self()
    pid = start(fn _, _, _, _ -> send(me, :rec) && :recorded end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, failed_event(:"pod.failed", %{"reason" => "boom", "no_pod_id" => true}))
        refute_receive :rec, 100
      end)

    assert log =~ "producer bug"
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
       subscribe: false,
       record_fun: fn _, _, _, _ -> :recorded end,
       escalate_fun: escalate_fun,
       routing_fun: fn -> routing() end}
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
          Fleet.Event.new(:starfleet, :"starfleet.audit_cat5_workflow_map_failed",
            payload: %{"reason" => "map KO"}
          )
        )

        # synchronize: the handle_info is processed before the call returns
        _ = :sys.get_state(pid)
      end)

    assert log =~ "Cat-5"
    assert log =~ "escalation FAILED"
    assert Process.alive?(pid)
  end

  describe "offload_async/1 — a saturated pool records INLINE, never drops" do
    # The incident is the durable memory the escalation chain rests on (the Warden's HALT
    # assumes the sysadmin issue was opened by this rail) — and a failure burst is exactly
    # when the pool saturates. max_children: 0 = permanent saturation.
    test "pool saturated → the work still runs (inline), {:ok, :inline}" do
      start_supervised!(
        {Task.Supervisor, name: IncidentConsumer.task_supervisor(), max_children: 0}
      )

      me = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :inline} = IncidentConsumer.offload_async(fn -> send(me, :recorded) end)
        end)

      assert_received :recorded
      assert log =~ "INLINE"
    end

    test "inline fallback isolates a crashing record (the singleton must survive)" do
      start_supervised!(
        {Task.Supervisor, name: IncidentConsumer.task_supervisor(), max_children: 0}
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :inline_crashed} =
                   IncidentConsumer.offload_async(fn -> raise "poisoned payload" end)
        end)

      assert log =~ "INLINE fallback crashed"
    end

    test "pool available → offloaded as before, {:ok, :offloaded}" do
      start_supervised!(
        {Task.Supervisor, name: IncidentConsumer.task_supervisor(), max_children: 4}
      )

      me = self()
      assert {:ok, :offloaded} = IncidentConsumer.offload_async(fn -> send(me, :recorded) end)
      assert_receive :recorded, 500
    end
  end
end
