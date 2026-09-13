defmodule Fleet.TaskQueueTest do
  @moduledoc """
  In-memory broker transitions, validation, retention and broadcast-failure retries.
  Anonymous servers and test topics isolate state. Custom topics bypass the production
  bus's main-to-pod fan-out; these tests do not establish exactly-once completion delivery.
  """
  use ExUnit.Case, async: true
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.TaskQueue
  alias Fleet.TaskQueue.Server

  # Return failure without delivering; lifecycle failure must remain visible to the caller.
  defmodule FailBus do
    def broadcast(_topic, _ev), do: {:error, :forced_broadcast_fail}
  end

  # Raise a registry exception without delivering, exercising required-broadcast rescue.
  defmodule RaiseBus do
    def broadcast(_topic, _ev), do: raise(Fleet.Event.UnregisteredError, "forced raise")
  end

  # Per-topic switch from zero-delivery failure to real Bus delivery. It does not simulate
  # deliver-then-error or the main-topic pod fan-out failure window.
  defmodule ToggleBus do
    def broadcast(topic, ev) do
      case :persistent_term.get({__MODULE__, topic}, :fail) do
        :deliver -> Fleet.EventRouter.Bus.broadcast(topic, ev)
        :fail -> {:error, :toggled_fail}
      end
    end
  end

  setup do
    topic = "fleet.events.test.#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Fleet.PubSub, topic)
    {:ok, q} = start_supervised({Server, name: nil, topic: topic})
    %{q: q, topic: topic}
  end

  test "1. enqueue + get_for_pod happy path", %{q: q} do
    {:ok, task} = TaskQueue.enqueue(q, "pod-A", %{brief: "fix X", role: "engineer"})
    assert task.state == :pending
    tid = task.id

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :"work_item.enqueued",
      pod_id: "pod-A",
      correlation_id: ^tid,
      # F144: payload = %{work_item_id} (consistent + JSON-safe), no longer the raw %WorkItem{}.
      payload: %{work_item_id: ^tid}
    }

    {:ok, assigned} = TaskQueue.get_for_pod(q, "pod-A")
    assert %{state: :assigned, id: ^tid} = assigned

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :"work_item.assigned",
      pod_id: "pod-A",
      correlation_id: ^tid
    }
  end

  test "AXIOM cleanup: enqueue supersedes the pod's existing :pending (1 active work item/pod, the fresh one wins)",
       %{q: q} do
    {:ok, _stale} = TaskQueue.enqueue(q, "pod-X", %{brief: "stale", role: "engineer"})
    {:ok, fresh} = TaskQueue.enqueue(q, "pod-X", %{brief: "fresh", role: "engineer"})

    assert [%{brief: "fresh", state: :pending} = only] =
             TaskQueue.list_pending(q) |> Enum.filter(&(&1.pod_id == "pod-X"))

    assert only.id == fresh.id
    # get_for_pod serves the fresh one, not the residue
    assert {:ok, %{brief: "fresh"}} = TaskQueue.get_for_pod(q, "pod-X")
  end

  test "last_poll: get_for_pod records the poll EVEN without a work item (in-band bootstrap ACK)",
       %{
         q: q
       } do
    assert TaskQueue.last_poll(q, "pod-boot") == nil
    # no work item → :no_work_item, but the agent REACHED OUT → the poll is recorded
    assert {:error, :no_work_item} = TaskQueue.get_for_pod(q, "pod-boot")
    assert %DateTime{} = TaskQueue.last_poll(q, "pod-boot")
  end

  test "last_poll: also tracked on a pull (with work item)", %{q: q} do
    {:ok, _} = TaskQueue.enqueue(q, "pod-W", %{brief: "x", role: "engineer"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-W")
    assert %DateTime{} = TaskQueue.last_poll(q, "pod-W")
  end

  test "last_poll: clear_for_pod forgets the pod's poll (no dead pod_id accumulation)", %{
    q: q
  } do
    # The pod reached out (poll recorded), then gets decommissioned via clear_for_pod.
    {:error, :no_work_item} = TaskQueue.get_for_pod(q, "pod-dead")
    assert %DateTime{} = TaskQueue.last_poll(q, "pod-dead")

    assert :ok = TaskQueue.clear_for_pod(q, "pod-dead")
    # Clear is the pod's canonical purge point → its last-poll is forgotten (otherwise `polls`
    # would accumulate dead pod_ids indefinitely).
    assert TaskQueue.last_poll(q, "pod-dead") == nil
  end

  test "2. get_for_pod idempotent (survives one_shot /clear, no double dispatch)", %{q: q} do
    {:ok, t1} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    assert_receive %Fleet.Event{type: :"work_item.enqueued"}

    {:ok, a1} = TaskQueue.get_for_pod(q, "pod-A")
    assert_receive %Fleet.Event{type: :"work_item.assigned"}

    # 2nd call → SAME work item, NO new :"work_item.assigned" broadcast
    {:ok, a2} = TaskQueue.get_for_pod(q, "pod-A")
    assert a1.id == t1.id
    assert a2.id == a1.id
    refute_receive %Fleet.Event{type: :"work_item.assigned"}, 100
  end

  test "3. submit_result happy path", %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    tid = t.id

    {:ok, completed} =
      TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven", "artifacts" => []})

    assert completed.state == :completed

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :"work_item.completed",
      pod_id: "pod-A",
      correlation_id: ^tid,
      payload: %{result: %{"verdict" => "proven"}}
    }
  end

  test "3d. D4 — the broker ENGRAVES the work item's brief_sha, overwriting the pod's citation",
       %{
         q: q
       } do
    # The dispatched string-key citation wins. This synthetic SHA checks propagation,
    # not resolution of a real commit or handling of conflicting atom-key citations.
    runtime_sha = String.duplicate("a", 40)

    {:ok, _} =
      TaskQueue.enqueue(q, "pod-A", %{
        brief: "x",
        brief_sha: runtime_sha,
        brief_ref: "gate-briefs/issue-1-reviewer.md"
      })

    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")

    {:ok, _} =
      TaskQueue.submit_result(q, "pod-A", %{
        "verdict" => "proven",
        "brief_sha" => String.duplicate("b", 40)
      })

    assert_receive %Fleet.Event{
      type: :"work_item.completed",
      payload: %{
        result: %{
          "brief_sha" => ^runtime_sha,
          "brief_ref" => "gate-briefs/issue-1-reviewer.md"
        }
      }
    }
  end

  # Required completion failures must not be acknowledged as successful submissions.
  test "3b. MA-04: work_item.completed broadcast RETURNING {:error} → submit_result {:error,{:broadcast_failed,_}}, not {:ok}" do
    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: "t.failbus", bus: FailBus},
        id: :q_failbus
      )

    {:ok, _t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")

    result = TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})

    # NOT a mute success. The caller SEES the lifecycle failure.
    refute match?({:ok, _}, result)
    assert {:error, {:broadcast_failed, :forced_broadcast_fail}} = result
  end

  test "CI-09: Broadcast.lossy LOGS the PubSub {:error} delivery failure (was silently discarded), still :ok" do
    ev = Fleet.Event.new(:spawner, :"pod.failed", payload: %{"pod_id" => "p1"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # Fire-and-forget contract preserved (:ok), but the delivery loss is now VISIBLE — this path
        # bypasses Bus.safe_emit (event already built), so it logs its own lossy loss.
        assert :ok = Fleet.TaskQueue.Broadcast.lossy(FailBus, "t.x", ev)
      end)

    assert log =~ "lossy" and log =~ "NOT delivered" and log =~ "forced_broadcast_fail"
  end

  # MA-04 — variant: the broadcast RAISES (UnregisteredError / PubSub down). `required_broadcast` rescues
  # and propagates `{:error,{:broadcast_failed,_}}`, never a mute `:ok` (the rescue does not re-swallow lifecycle).
  test "3c. MA-04: work_item.completed broadcast that RAISES → {:error,{:broadcast_failed,_}}, not {:ok}" do
    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: "t.raisebus", bus: RaiseBus},
        id: :q_raisebus
      )

    {:ok, _t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")

    result = TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})

    refute match?({:ok, _}, result)
    assert {:error, {:broadcast_failed, _}} = result
  end

  test "4. submit_result idempotent (double submit ignored, no double broadcast)", %{q: q} do
    {:ok, item} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")

    {:ok, _} =
      TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven", "work_item_id" => item.id})

    assert_receive %Fleet.Event{type: :"work_item.completed"}

    # Preserve the same id as the MCP correlator. Pod-wide completion history alone cannot
    # establish that this particular mandate was already accepted.
    assert {:error, :double_submit_ignored} =
             TaskQueue.submit_result(q, "pod-A", %{
               "verdict" => "proven",
               "work_item_id" => item.id
             })

    refute_receive %Fleet.Event{type: :"work_item.completed"}, 100
  end

  test "a CLEARED mandate's result is NOT acknowledged because an EARLIER one completed", %{q: q} do
    # Completed A must not falsely acknowledge cleared B. MCP presents double_submit_ignored
    # as already received, so a pod-wide predicate would hide loss of B's result.
    {:ok, a} = TaskQueue.enqueue(q, "pod-lie", %{brief: "A"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-lie")
    {:ok, _} = TaskQueue.submit_result(q, "pod-lie", %{"verdict" => "ok", "work_item_id" => a.id})
    assert_receive %Fleet.Event{type: :"work_item.completed"}

    {:ok, b} = TaskQueue.enqueue(q, "pod-lie", %{brief: "B"})
    :ok = TaskQueue.clear_for_pod(q, "pod-lie")

    # B's result must NOT be acknowledged: nothing of B was ever received.
    assert {:error, :no_active_work_item} =
             TaskQueue.submit_result(q, "pod-lie", %{"verdict" => "b", "work_item_id" => b.id})

    # And A's own re-submit is still recognised — the fix narrows the answer, it does not remove it.
    assert {:error, :double_submit_ignored} =
             TaskQueue.submit_result(q, "pod-lie", %{"verdict" => "ok", "work_item_id" => a.id})
  end

  test "a mandate never PULLED cannot be closed — and the id error still wins when it applies", %{
    q: q
  } do
    # State must enforce pull-before-close even for a caller already holding the id from enqueue.
    {:ok, pending} = TaskQueue.enqueue(q, "pod-quiet", %{brief: "never pulled"})

    assert {:error, :work_item_not_pulled} =
             TaskQueue.submit_result(q, "pod-quiet", %{
               "verdict" => "x",
               "work_item_id" => pending.id
             })

    # ORDER MATTERS: a stale id submitted while a pending item is active must still name the id
    # problem, not the state one — otherwise the refusal describes a mandate the pod never meant to
    # close.
    assert {:error, :work_item_id_mismatch} =
             TaskQueue.submit_result(q, "pod-quiet", %{
               "verdict" => "x",
               "work_item_id" => "stale"
             })

    # And pulling it makes the close legitimate again — the guard gates on READING, nothing else.
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-quiet")

    assert {:ok, %{state: :completed}} =
             TaskQueue.submit_result(q, "pod-quiet", %{
               "verdict" => "x",
               "work_item_id" => pending.id
             })
  end

  # Failed broadcasts leave the item active, allowing retry instead of a false duplicate response.
  test "CI-03: a FAILED broadcast leaves the item ACTIVE + a re-submit RE-ATTEMPTS (never double_submit_ignored)" do
    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: "t.ci03.active", bus: FailBus},
        id: :q_ci03_active
      )

    {:ok, _t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")

    assert {:error, {:broadcast_failed, :forced_broadcast_fail}} =
             TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})

    # NOT committed → the item is still ACTIVE (owns the slot; reclaimable if the pod dies).
    assert {:ok, :assigned} = TaskQueue.pod_status(q, "pod-A")

    # A re-submit RE-ATTEMPTS the delivery (fails again here) — it is NOT the false `:double_submit_ignored`.
    assert {:error, {:broadcast_failed, :forced_broadcast_fail}} =
             TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})
  end

  test "CI-03: a re-submit after a failed broadcast RE-PLAYS the delivery, exactly once → :completed" do
    topic = "t.ci03.toggle.#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Fleet.PubSub, topic)
    :persistent_term.put({ToggleBus, topic}, :fail)
    on_exit(fn -> :persistent_term.erase({ToggleBus, topic}) end)

    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: topic, bus: ToggleBus},
        id: :q_ci03_toggle
      )

    {:ok, _t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")

    # 1st submit: broadcast fails → nothing committed, nothing delivered, item stays active.
    assert {:error, {:broadcast_failed, :toggled_fail}} =
             TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})

    assert {:ok, :assigned} = TaskQueue.pod_status(q, "pod-A")
    refute_receive %Fleet.Event{type: :"work_item.completed"}, 100

    # Bus heals → the re-submit RE-PLAYS: delivers exactly once, item becomes :completed.
    :persistent_term.put({ToggleBus, topic}, :deliver)

    assert {:ok, completed} = TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})
    assert completed.state == :completed
    assert_receive %Fleet.Event{type: :"work_item.completed"}
    assert {:ok, :completed} = TaskQueue.pod_status(q, "pod-A")

    # NOW genuinely delivered → a further double-submit IS ignored (no second emission).
    assert {:error, :double_submit_ignored} =
             TaskQueue.submit_result(q, "pod-A", %{
               "verdict" => "proven",
               "work_item_id" => completed.id
             })

    refute_receive %Fleet.Event{type: :"work_item.completed"}, 100
  end

  test "6f. WorkItem.new/2 = smart-constructor: casts (deadline ISO→DateTime), rejects a malformed attr" do
    alias Fleet.TaskQueue.WorkItem

    assert {:ok,
            %WorkItem{
              deadline: %DateTime{},
              metadata: %{"k" => "v"},
              state: :pending
            }} =
             WorkItem.new("p1", %{deadline: "2026-06-02T00:00:00Z", metadata: %{"k" => "v"}})

    assert {:ok, %WorkItem{deadline: nil}} = WorkItem.new("p1", %{})
    assert {:error, {:bad_attr, {:metadata, _}}} = WorkItem.new("p1", %{metadata: "nope"})
    assert {:error, {:bad_attr, {:deadline, _}}} = WorkItem.new("p1", %{deadline: 12_345})
    assert {:error, {:bad_attr, {:issue_id, _}}} = WorkItem.new("p1", %{issue_id: 7})

    # A malformed string is distinct from both an integer and an absent deadline:
    # silently converting it to nil would create work with no expiry.
    assert {:error, {:bad_attr, {:deadline, "pas-une-date"}}} =
             WorkItem.new("p1", %{deadline: "pas-une-date"})

    # BND-123: brief_sha/brief_ref are the ADDRESS of the physical brief, not free text. A bogus
    # sha would pass itself off as verifiable provenance in the MCP envelope → shape validated at
    # cast (via the Fleet.Layout truth — same source as the producer).
    valid_sha = String.duplicate("a", 40)
    assert {:ok, %WorkItem{brief_sha: ^valid_sha}} = WorkItem.new("p1", %{brief_sha: valid_sha})

    # plain human names — worker AND judge routing both accepted; hintless sha256 name too
    assert {:ok, %WorkItem{brief_ref: "briefs/issue-3-engineer.md"}} =
             WorkItem.new("p1", %{brief_ref: "briefs/issue-3-engineer.md"})

    assert {:ok, %WorkItem{brief_ref: "gate-briefs/" <> _}} =
             WorkItem.new("p1", %{brief_ref: "gate-briefs/issue-3-consultant.md"})

    assert {:ok, %WorkItem{brief_ref: "briefs/" <> _}} =
             WorkItem.new("p1", %{brief_ref: "briefs/#{String.duplicate("c", 64)}.md"})

    # nil stays nil (legitimate degraded/best-effort state, DR-010)
    assert {:ok, %WorkItem{brief_sha: nil, brief_ref: nil}} = WorkItem.new("p1", %{})
    # out-of-shape sha (too short = not a commit sha, uppercase, non-hex) → rejected
    assert {:error, {:bad_attr, {:brief_sha, _}}} = WorkItem.new("p1", %{brief_sha: "def"})

    assert {:error, {:bad_attr, {:brief_sha, _}}} =
             WorkItem.new("p1", %{brief_sha: String.upcase(valid_sha)})

    # out-of-shape ref (traversal, foreign subdir, nested path) → rejected
    assert {:error, {:bad_attr, {:brief_ref, _}}} =
             WorkItem.new("p1", %{brief_ref: "../escape.md"})

    assert {:error, {:bad_attr, {:brief_ref, _}}} = WorkItem.new("p1", %{brief_ref: "other/x.md"})

    assert {:error, {:bad_attr, {:brief_ref, _}}} =
             WorkItem.new("p1", %{brief_ref: "briefs/a/b.md"})
  end

  test "6g. enqueue propagates the smart-constructor error + casts the ISO deadline", %{
    topic: topic
  } do
    {:ok, q} = start_supervised({Server, name: nil, topic: topic}, id: :qenq)

    assert {:error, {:bad_attr, {:deadline, 42}}} = TaskQueue.enqueue(q, "p1", %{deadline: 42})
    assert [] = TaskQueue.list_pending(q)

    assert {:ok, %{deadline: %DateTime{}}} =
             TaskQueue.enqueue(q, "p2", %{deadline: "2030-01-01T00:00:00Z"})
  end

  test "MINE-TQ-02: max-DateTime deadline (year 9999) → enqueue does NOT crash the GenServer (timer clamp)",
       %{topic: topic} do
    {:ok, q} = start_supervised({Server, name: nil, topic: topic}, id: :qfar)

    # Exceeds the timer's 32-bit millisecond interval; enqueue must clamp rather than crash.
    far = ~U[9999-12-31 23:59:59Z]

    assert {:ok, %{deadline: %DateTime{}}} = TaskQueue.enqueue(q, "p1", %{deadline: far})

    assert Process.alive?(q),
           "the TaskQueue GenServer crashed on a far deadline (send_after not clamped)"

    assert [%{pod_id: "p1", state: :pending}] = TaskQueue.list_pending(q)
  end

  test "MINE-TQ-02: PREMATURE check_deadline (deadline not reached) → re-arms, does NOT fail", %{
    topic: topic
  } do
    {:ok, q} = start_supervised({Server, name: nil, topic: topic}, id: :qearly)

    # An early check must leave the item active. This test does not observe the rearmed timer.
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, wi} = TaskQueue.enqueue(q, "p1", %{deadline: future})

    send(q, {:check_deadline, wi.id})
    # list_pending = synchronous call → flushes the check_deadline (FIFO) before the assert.
    assert [%{pod_id: "p1", state: :pending}] = TaskQueue.list_pending(q)
  end

  test "MINE-TQ-01: STALE polls (> TTL) are purged → `polls` bounded (dead pod without clear does not leak)",
       %{topic: topic} do
    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: topic, poll_retention_ms: 30},
        id: :qpolls
      )

    # podA polls (get_for_pod records the poll even without a work item = bootstrap signal)
    TaskQueue.get_for_pod(q, "podA")
    assert %DateTime{} = TaskQueue.last_poll(q, "podA")

    # past the TTL (30ms) without re-poll nor clear: podB polls → podA's STALE poll is purged
    Process.sleep(60)
    TaskQueue.get_for_pod(q, "podB")

    assert TaskQueue.last_poll(q, "podA") == nil,
           "podA's stale poll (dead pod without clear) should have been purged"

    assert %DateTime{} = TaskQueue.last_poll(q, "podB")
  end

  test "7. failed via deadline", %{q: q} do
    deadline = DateTime.add(DateTime.utc_now(), 200, :millisecond)
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x", deadline: deadline})
    tid = t.id
    assert_receive %Fleet.Event{type: :"work_item.enqueued"}

    # Five-second test margin tolerates scheduler load; the 200ms deadline is not a latency SLA.
    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :"work_item.failed",
                     correlation_id: ^tid,
                     payload: %{reason: :deadline_expired}
                   },
                   5000

    assert {:ok, :failed} = TaskQueue.pod_status(q, "pod-A")
  end

  test "8. list_pending (Query Port, no broadcast)", %{q: q} do
    for n <- 1..5, do: TaskQueue.enqueue(q, "pod-#{n}", %{brief: "t#{n}"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-1")
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-2")
    # 5 enqueue - 2 assigned = 3 pending
    assert [_, _, _] = TaskQueue.list_pending(q)
  end

  test "8bis. list_active = pending+assigned; cleared (supersede) and completed EXCLUDED",
       %{q: q} do
    # 3 pods: A assigned (pulled), B pending (never pulled), C completed — then D superseded.
    {:ok, _} = TaskQueue.enqueue(q, "pod-A", %{brief: "a"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    {:ok, _} = TaskQueue.enqueue(q, "pod-B", %{brief: "b"})
    {:ok, tc} = TaskQueue.enqueue(q, "pod-C", %{brief: "c"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-C")
    {:ok, _} = TaskQueue.submit_result(q, "pod-C", %{"work_item_id" => tc.id, "out" => "ok"})

    # D: the 1st work item is SUPERSEDED (:cleared) by the 2nd at enqueue (1-active/pod axiom held
    # at write time) → only the 2nd is active. This is the G1 "clobbered eval" case: the cleared one
    # must NOT be owned (otherwise an orphan lock would be masked forever by a ghost).
    {:ok, d1} = TaskQueue.enqueue(q, "pod-D", %{brief: "d1"})
    {:ok, d2} = TaskQueue.enqueue(q, "pod-D", %{brief: "d2"})

    active = TaskQueue.list_active(q)
    active_ids = MapSet.new(active, & &1.id)

    # A (assigned) + B (pending) + D2 (pending) = 3 active; C (completed) and D1 (cleared) excluded.
    assert length(active) == 3
    assert MapSet.member?(active_ids, d2.id)
    refute MapSet.member?(active_ids, d1.id)
    refute MapSet.member?(active_ids, tc.id)
    assert Enum.all?(active, &(&1.state in [:pending, :assigned]))
  end

  test "9. clear_for_pod", %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    tid = t.id

    assert :ok = TaskQueue.clear_for_pod(q, "pod-A")

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :"work_item.cleared",
      pod_id: "pod-A",
      correlation_id: ^tid
    }

    assert {:ok, :cleared} = TaskQueue.pod_status(q, "pod-A")
  end

  test "10. %Fleet.Event{} schema conformance on events", %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})

    assert_receive %Fleet.Event{} = ev
    assert ev.source == :task_queue
    # enforce_keys present
    assert ev.timestamp != nil and ev.type != nil
    # correlation_id == task.id when a work item exists
    assert ev.correlation_id == t.id
    assert Fleet.Event.valid_source?(ev.source)
  end

  test "11. submit_result with work_item_id ≠ active work item → :work_item_id_mismatch (§A.70, no mutation)",
       %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    assert_receive %Fleet.Event{type: :"work_item.enqueued"}
    assert_receive %Fleet.Event{type: :"work_item.assigned"}

    # The pod returns a forged/stale work_item_id ≠ its active work item → rejected.
    assert {:error, :work_item_id_mismatch} =
             TaskQueue.submit_result(q, "pod-A", %{
               "work_item_id" => "forged-uuid",
               "verdict" => "x"
             })

    # No mutation: the work item stays active, no :"work_item.completed".
    assert {:ok, :assigned} = TaskQueue.pod_status(q, "pod-A")
    refute_receive %Fleet.Event{type: :"work_item.completed"}, 100

    # With the right work_item_id → OK.
    assert {:ok, _} =
             TaskQueue.submit_result(q, "pod-A", %{"work_item_id" => t.id, "verdict" => "ok"})

    assert_receive %Fleet.Event{type: :"work_item.completed"}
  end

  test "12. F148 — retention bounds terminal work items (active ones intact + double-submit of the most recent)",
       %{topic: topic} do
    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: topic, retention_terminal_max: 3},
        id: :qret
      )

    # 5 pods driven to completion (terminal :completed); cap = 3.
    for i <- 1..5 do
      pod = "pod-#{i}"
      {:ok, _} = TaskQueue.enqueue(q, pod, %{brief: "b#{i}"})
      {:ok, _} = TaskQueue.get_for_pod(q, pod)
      {:ok, _} = TaskQueue.submit_result(q, pod, %{"verdict" => "ok"})
    end

    # + one ACTIVE work item: must NEVER be pruned.
    {:ok, _} = TaskQueue.enqueue(q, "pod-active", %{brief: "in progress"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-active")

    work_items = settle(q).work_items |> Map.values()
    terminal = Enum.filter(work_items, &(&1.state == :completed))
    active = Enum.filter(work_items, &(&1.state in [:pending, :assigned]))

    # Hard bound: 5 completed → at most 3 kept (2 pruned).
    assert length(terminal) == 3
    # The active one always survives (never counted nor cut).
    assert [%{pod_id: "pod-active", state: :assigned}] = active

    # Retain the newest completion in this fixture so its duplicate remains recognizable.
    kept5 = Enum.find(terminal, &(&1.pod_id == "pod-5"))

    # A historical intermittent loss of pod-5 remains unexplained. Keep survivor timestamps
    # in the failure message; previous non-reproduction did not rule out clock/tie causes.
    assert kept5,
           "pod-5 (most recently completed) was pruned, which would degrade a double-submit into " <>
             ":no_active_work_item. Survivors, with the timestamps retention sorted on: " <>
             inspect(Enum.map(terminal, &{&1.pod_id, &1.completed_at}), limit: :infinity)

    assert {:error, :double_submit_ignored} =
             TaskQueue.submit_result(q, "pod-5", %{
               "verdict" => "retry",
               "work_item_id" => kept5.id
             })
  end

  # Inspect stored state, not just newest-item selection, to catch a leaked assigned predecessor.
  test "MA-27 re-brief of a pod with an existing :assigned → ONLY 1 active (the old one :cleared)",
       %{
         q: q
       } do
    {:ok, old} = TaskQueue.enqueue(q, "pod-Z", %{brief: "old work item"})
    # pull → the old one goes :assigned (the pod is "working on it").
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-Z")
    assert {:ok, :assigned} = TaskQueue.pod_status(q, "pod-Z")

    # RE-BRIEF: a fresh new work item (forge re-dispatch) arrives WHILE the old one is :assigned.
    {:ok, fresh} = TaskQueue.enqueue(q, "pod-Z", %{brief: "new work item"})

    work_items = settle(q).work_items |> Map.values()

    active =
      Enum.filter(
        work_items,
        &(&1.pod_id == "pod-Z" and &1.state in [:pending, :assigned])
      )

    # ONLY 1 active = the fresh one (:pending). The old :assigned is superseded → :cleared.
    assert [%{state: :pending} = only] = active
    assert only.id == fresh.id

    old_now = Enum.find(work_items, &(&1.id == old.id))
    assert old_now.state == :cleared

    # Re-brief semantics validated: the pod takes the NEW work item at the next pull (only active left).
    fresh_id = fresh.id
    assert {:ok, %{brief: "new work item", id: ^fresh_id}} = TaskQueue.get_for_pod(q, "pod-Z")

    # And the old work item can no longer mutate the queue: its submit hits an active = the fresh one
    # (work_item_id mismatch) — never a completion of the old ghost.
    assert {:error, :work_item_id_mismatch} =
             TaskQueue.submit_result(q, "pod-Z", %{"work_item_id" => old.id, "verdict" => "stale"})
  end

  test "supersede EMITS work_item.cleared (no mute terminal transition — trace + consumer purge)",
       %{q: q, topic: _topic} do
    # Cleared events let consumers retire per-mandate context; this checks emission, not their cleanup.
    {:ok, old} = TaskQueue.enqueue(q, "pod-S", %{brief: "old"})
    assert_receive %Fleet.Event{type: :"work_item.enqueued"}

    {:ok, _fresh} = TaskQueue.enqueue(q, "pod-S", %{brief: "fresh"})

    old_id = old.id

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :"work_item.cleared",
      correlation_id: ^old_id,
      payload: %{work_item_id: ^old_id, reason: :superseded}
    }
  end

  # Deliberately bypass enqueue uniqueness with two active items; clear must handle both.
  test "MA-27 clear_for_pod purges ALL of the pod's active items (total clear, not just the most recent)",
       %{
         q: q
       } do
    {:ok, t1} = TaskQueue.enqueue(q, "pod-M", %{brief: "m1"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-M")

    # Inject a 2nd active (:assigned) for the SAME pod, bypassing supersede_active (which in prod
    # guarantees uniqueness) — proving clear_for_pod LEAVES NO stale item even if there were any.
    :sys.replace_state(q, fn st ->
      ghost = %Fleet.TaskQueue.WorkItem{
        id: "ghost-uuid",
        pod_id: "pod-M",
        enqueued_at: DateTime.add(t1.enqueued_at, -60, :second),
        state: :assigned
      }

      %{st | work_items: Map.put(st.work_items, ghost.id, ghost)}
    end)

    assert :ok = TaskQueue.clear_for_pod(q, "pod-M")

    work_items = settle(q).work_items |> Map.values()

    active =
      Enum.filter(
        work_items,
        &(&1.pod_id == "pod-M" and &1.state in [:pending, :assigned])
      )

    assert active == []
    assert Enum.all?(work_items, &(&1.pod_id != "pod-M" or &1.state == :cleared))
  end
end
