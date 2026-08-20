defmodule Fleet.TaskQueueTest do
  @moduledoc """
  Broker conformance tests — DN `orchestration/task-queue` §G (10 tests).
  Every `assert_receive` matches the canonical `%Fleet.Event{}` schema.

  Async isolation: one unique PubSub topic per test (canonical default `fleet.events`
  overridden via the `:topic` opt). Le `@moduletag :tmp_dir` est parti le 2026-08-20 avec le
  `state.json` qu'il abritait (BL-6-113) : le broker n'ecrit plus rien sur disque.
  """
  use ExUnit.Case, async: true

  alias Fleet.TaskQueue
  alias Fleet.TaskQueue.Server

  # MA-04 — bus stub: `broadcast/2` RETURNS `{:error, _}` (simulates a refusing PubSub, e.g.
  # a downgraded UnregisteredError). The lifecycle path must propagate, not swallow.
  defmodule FailBus do
    def broadcast(_topic, _ev), do: {:error, :forced_broadcast_fail}
  end

  # MA-04 — bus stub: `broadcast/2` RAISES (simulates UnregisteredError / PubSub not started).
  # `required_broadcast` must rescue → `{:error, {:broadcast_failed, _}}`, never a mute `:ok`.
  defmodule RaiseBus do
    def broadcast(_topic, _ev), do: raise(Fleet.Event.UnregisteredError, "forced raise")
  end

  # CI-03 — bus stub whose behavior is TOGGLED per-topic (topics are unique per test → async-safe):
  # `:fail` returns `{:error, _}` (no delivery), `:deliver` delegates to the real Bus (the registry-gate
  # is traversed — permitted since the registry is empty in test — then Phoenix.PubSub delivers for real).
  # Lets one test simulate a broadcast that FAILS then HEALS across a re-submit.
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

    # a SINGLE :pending for pod-X = the fresh one; the stale one is superseded → no intra-session
    # pile-up. [[single-source axiom: cleaned up when no longer true]]
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

  # MA-04 — THE finding: `work_item.completed` is load-bearing LIFECYCLE (StepRunConsumer depends on it to
  # finish the step_run). If its broadcast fails, `submit_result` does NOT return a mute `{:ok}` (the pod would
  # believe its deliverable accepted while the step_run never finishes → forge lock forever) — it propagates
  # `{:error,{:broadcast_failed,_}}`.
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

    # The re-submit carries the SAME id, which is what a pod really sends: the MCP layer injects
    # `work_item_id` on every call and the tool schema requires it. The id-less form these tests
    # used to make is unreachable from a pod, and reading a double-submit off "this pod completed
    # something once" is what let a CLEARED mandate be acknowledged (cf. `completed_submit?/3`).
    assert {:error, :double_submit_ignored} =
             TaskQueue.submit_result(q, "pod-A", %{
               "verdict" => "proven",
               "work_item_id" => item.id
             })

    refute_receive %Fleet.Event{type: :"work_item.completed"}, 100
  end

  test "a CLEARED mandate's result is NOT acknowledged because an EARLIER one completed", %{q: q} do
    # THE LIE THIS PREDICATE USED TO TELL. `:double_submit_ignored` is not an error to the pod: the
    # MCP layer turns it into `{:ok, "Result already received (ignored)."}`. So answering it on the
    # wrong grounds tells a pod its work landed while the result goes in the bin.
    #
    # Sequence, and nothing in it is exotic: A is completed, B is enqueued (superseding nothing, A
    # is terminal), a teardown clears B, and B's submit — already in flight on the socket — lands.
    # `find_active` is nil; the old predicate saw A and answered "already received" about B.
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
    # Unreachable through the pod today, and that is the point: the id is only obtainable through
    # `get_work_item`, which assigns the item on its way out. So "the pod read its brief before
    # closing it" held as a property of id-distribution, not of the state machine.
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

  # CI-03 — broadcast BEFORE commit. A failed `work_item.completed` broadcast must NOT commit the
  # terminal `:completed` state: the item STAYS ACTIVE so a re-submit RE-PLAYS the delivery instead of
  # being lied to with `:double_submit_ignored` (pre-CI-03 the commit was done first → lost broadcast =
  # terminal item + false "already received" at retry).
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

  # ═══ HUIT TESTS DE RECUPERATION RETIRES LE 2026-08-20 AVEC LEUR RAIL (BL-6-113) ═══
  #
  # `5. recovery cross-restart` · `6. schema mismatch -> state.corrupt` · `6b. from_map round-trip`
  # · `6c. etat inconnu -> state.corrupt` · `6d-bis` · `6d-ter` · `6d` · `6e. from_map optionnel
  # malforme`. Tous interrogeaient `Fleet.TaskQueue.Store` et `WorkItem.from_map/to_map`, supprimes :
  # le broker n'ecrit plus de `state.json`, donc il n'a rien a relire et pas d'etat a trouver
  # corrompu.
  #
  # CE QU'ILS PROUVAIENT ET QUI NE DOIT PAS PARTIR AVEC EUX — verifie, pas suppose :
  #
  #   * « une echeance ILLISIBLE n'est pas une absence d'echeance » (6d-bis/6d-ter, JG-020) : la
  #     distinction vit maintenant dans `new/2` (`cast_deadline`), et `6f` l'epingle — l'assertion
  #     sur la chaine illisible y a ete AJOUTEE le meme jour, parce que `6f` ne couvrait que
  #     l'entier et l'absence. Sans cet ajout, retirer 6d-bis aurait rendu la propriete a personne ;
  #   * « une echeance deja passee sur un item actif le fait echouer » (6e-recovery) : couvert par
  #     `7. failed via deadline`, qui l'obtient par `enqueue` au lieu d'une relecture ;
  #   * « un timer au-dela du plafond ERTS est borne » (MINE-TQ-02 recovery) : couvert par
  #     `MINE-TQ-02: max-DateTime deadline`, meme clamp, atteint par `enqueue`.
  #
  # Ce qui part vraiment : la serialisation et sa reciproque. Une paire de fonctions dont la seule
  # preuve etait qu'elles s'inversent l'une l'autre ne prouvait rien du systeme.

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

    # JG-020, RAPATRIE ICI LE 2026-08-20 DEPUIS `6d-bis` (parti avec `from_map`). ABSENTE et
    # ILLISIBLE sont deux faits, et un seul est une absence d'echeance. Le couple juste au-dessus
    # ne couvrait que l'ENTIER et l'ABSENCE : une CHAINE qu'on ne sait pas lire etait le cas non
    # teste, et c'est precisement celui qui, plie sur `nil`, produisait un mandat que la file ne
    # ferait JAMAIS expirer — `deadline_reached?/1` ne conclut rien sur `nil`, donc l'item restait
    # la jusqu'a ce qu'un `enqueue` du meme pod le supersede.
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

  # (`6e. recovery re-arms active deadlines` retire le 2026-08-20 avec le rail : il ecrivait un
  #  `state.json` portant une echeance DEJA passee et attendait l'echec au boot. Le rearmement au
  #  demarrage n'existe plus — un broker neuf est vide. La propriete qu'il portait, « une echeance
  #  atteinte fait echouer l'item actif », est celle de `7. failed via deadline`.)

  test "MINE-TQ-02: max-DateTime deadline (year 9999) → enqueue does NOT crash the GenServer (timer clamp)",
       %{topic: topic} do
    {:ok, q} = start_supervised({Server, name: nil, topic: topic}, id: :qfar)

    # Elixir's MAX valid DateTime: ms ≈ 2.5e14 > the ERTS `Process.send_after` ceiling → without a clamp,
    # `send_after` raises ArgumentError INSIDE handle_call(:enqueue) → GenServer crash (same at recovery).
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

    # deadline in 1h: a check_deadline arriving BEFORE it (clamped timer firing early) must NOT
    # fail the item — only a deadline ACTUALLY reached does.
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, wi} = TaskQueue.enqueue(q, "p1", %{deadline: future})

    send(q, {:check_deadline, wi.id})
    # list_pending = synchronous call → flushes the check_deadline (FIFO) before the assert.
    assert [%{pod_id: "p1", state: :pending}] = TaskQueue.list_pending(q)
  end

  # (`MINE-TQ-02: recovery of a far deadline` retire le 2026-08-20 avec le rail. Il visait le PIRE
  #  cas — une echeance lointaine PERSISTEE, rearmee au boot, qui sans borne faisait planter en
  #  BOUCLE puisque le `state.json` relu replantait a chaque redemarrage. Cette boucle ne peut plus
  #  se former : rien n'est relu. La borne elle-meme reste epinglee par le test ci-dessus, qui
  #  l'atteint par `enqueue`.)

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

    # 5 s, et le chiffre porte un raisonnement plutot qu'une habitude. Ce test affirme QUE le timer
    # part, pas qu'il part vite : la borne a 1 s affirmait en plus une LATENCE que personne ne
    # promet, et elle est tombee dans un `mix gate` charge (2426 tests, 71 s de sync) ou le
    # scheduler n'a pas rendu la main dans les 1200 ms cumules. Un rouge par charge de machine sur
    # une assertion plus stricte que le contrat est un faux negatif de la pire espece : il apprend a
    # relancer le gate au lieu de le lire. La borne large ne cache rien — un timer qui ne part
    # JAMAIS echoue toujours, quatre secondes plus tard.
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

    work_items = :sys.get_state(q).work_items |> Map.values()
    terminal = Enum.filter(work_items, &(&1.state == :completed))
    active = Enum.filter(work_items, &(&1.state in [:pending, :assigned]))

    # Hard bound: 5 completed → at most 3 kept (2 pruned).
    assert length(terminal) == 3
    # The active one always survives (never counted nor cut).
    assert [%{pod_id: "pod-active", state: :assigned}] = active

    # The most recently completed (pod-5) survives → double-submit ALWAYS detected, not degraded
    # into :no_active_work_item by a retention cutting the wrong item (recency, not FIFO).
    kept5 = Enum.find(terminal, &(&1.pod_id == "pod-5"))

    # ⚠ THE ABSENCE IS NAMED, BECAUSE IT HAPPENED AND SAID NOTHING. On 2026-08-15 this line failed
    # ONCE in ten runs of the suite, and the only trace was a `KeyError` on `kept5.id` -- "key :id
    # not found in: nil". Mute about what survived, mute about the timestamps retention sorted on,
    # so there was nothing left to diagnose afterwards.
    #
    # The two obvious causes were MEASURED AND RULED OUT: 300 direct replays of this scenario give
    # 0 `completed_at` ties and 0 prunings of pod-5, and this machine's wall clock never stepped
    # backwards across 158 million samples under load. The cause is UNKNOWN. This message is what
    # makes the next occurrence readable instead of arguable -- it is not a fix, and must not be
    # read as one.
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

  # MA-27 — "1 ACTIVE work item/pod" invariant held AT WRITE TIME. Re-briefing a pod carrying an
  # existing `:assigned` must SUPERSEDE it (→ `:cleared`): otherwise the old `:assigned` would LEAK
  # next to the new pending (invisible to the guards — `find_active`/`max_by` masks it without
  # removing it), leaving 2 active items instead of 1 (`supersede_active`, not `supersede_pending`).
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

    work_items = :sys.get_state(q).work_items |> Map.values()

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
    # A supersede without an event would make the item go :cleared behind a Logger.debug →
    # (a) the audit trace would lie by omission about a mandate's fate, (b) any consumer carrying
    # per-mandate context (StepRunConsumer.gate_evals: payload + ENTIRE workflow_map) would keep
    # it forever. The event frees it.
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

  # MA-27 — `clear_for_pod` purges ALL of the pod's active items (not just the most recent via
  # `find_active`). With the invariant held at enqueue there is normally only one; the test
  # deliberately plants TWO active items (bypassing uniqueness via the direct state map) to prove
  # that clear is TOTAL.
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

    work_items = :sys.get_state(q).work_items |> Map.values()

    active =
      Enum.filter(
        work_items,
        &(&1.pod_id == "pod-M" and &1.state in [:pending, :assigned])
      )

    assert active == []
    assert Enum.all?(work_items, &(&1.pod_id != "pod-M" or &1.state == :cleared))
  end
end
