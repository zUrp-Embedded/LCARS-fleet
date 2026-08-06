defmodule Fleet.TaskQueue.Server do
  @moduledoc """
  GenServer holding the queue IN RAM (a single writer). Atomic `state.json` persistence
  versioned `v: 1` (**opt-in**); `%Fleet.Event{}` events on the bus.

  SINGLE-SOURCE AXIOM: the **forge** is the truth of the work (issues/routes/PR); the
  broker is only its RAM FRONT. No `WorkItem` field is broker-only-durable (everything is
  re-derivable on forge re-dispatch) → **in prod the broker runs EPHEMERAL** (`persist: false`, cf.
  `Application`): no `state.json`, hence no stale persisted tasks that survive reboots.
  On restart, the queue re-derives itself from the forge polls (canonical
  reconciliation rail). The persistence below stays an **opt-in** mechanism (tested) for a
  future broker-only-durable state — NONE exists to this day.

  Broadcasts `%Fleet.Event{source: :task_queue, ...}` on `Phoenix.PubSub`
  topic `fleet.events`, `correlation_id = work_item.id`. Cross-restart recovery via
  `state.json` (fail-loud `:state.corrupt` on schema mismatch at READ, non-blocking
  fallback). On the WRITE side: `persist/1` never blocks a transition — a write failure is
  logged **error** (durability of the recovery point broken), **non-fatal** (we
  don't crash the broker over a disk blip); reconciliation goes through the
  forge-driven rail (re-dispatch from the forge state), not through this local persistence.

  ## Assumed bottleneck
  GenServer = intended serialization of state transitions (idempotence + atomic
  `state.json` write). The ETS-reads / pool optimization is **deferred** (trigger
  criterion: get_work_item/submit_result latency > 100ms). MVP: everything goes through `call`.

  ## Options
  `:name` (`nil` → anonymous, test isolation), `:state_path`, `:persist`,
  `:topic` (default `"fleet.events"`), `:retention_terminal_max` (max number
  of TERMINAL tasks kept, default 500; bounds `work_items` in memory AND the size
  of `state.json` rewritten on every mutation. ACTIVE tasks do not count),
  `:bus` (seam, default `Fleet.EventRouter.Bus`; module with `broadcast/2` — injected in test to
  exercise the non-swallowed `work_item.completed` lifecycle path).

  ## Broadcast — load-bearing vs lossy observability
  `work_item.completed` is LIFECYCLE load-bearing (the StepRunConsumer depends on it to finish the step_run) →
  `required_broadcast`: a failure is NOT swallowed, it propagates `{:error, {:broadcast_failed, _}}` to the caller
  of `submit_result` (no more mute `:ok` that leaves the forge lock for life). The other events
  (enqueued/assigned/cleared/failed-deadline/state.corrupt) = `lossy_broadcast` (observability, rescue).

  ## Split — what was extracted, what stays (and why)

  Two concerns extracted into stateless modules (the GenServer state no longer traverses them):

    * `Fleet.TaskQueue.Store` — `state.json` persistence (serialization + FS, atomic
      write, fail-loud `:corrupt` decoding). The Server keeps the ORCHESTRATION:
      `persist/1` decides WHETHER to persist (`persist: false` / `state_path: nil`),
      `load_state/2` decides WHETHER to reload — Store only knows how to read/write.
    * `Fleet.TaskQueue.Broadcast` — load-bearing vs lossy-observability policy + the
      `event/3` envelope. The Server keeps one-line adapters that unpack
      `state.bus`/`state.topic` (the per-instance seams).

  Two concerns REFUSED for extraction (2 clean cuts > 4 forced ones):

    * **Deadline-watchdog** (`maybe_schedule_deadline/1` + `handle_info {:check_deadline}`):
      the arm/check pair is coupled to the PROCESS (`Process.send_after(self(), ...)` →
      message received by THIS GenServer). Extracting the "arming" half would place a
      process-coupled side-effect in a leaf module while the receiving half
      (callback) stayed here: no coupling lifted, one indirection added.
    * **Retention/prune** (`prune_terminal/2` + `recency/1`): ~20 pure LOC, a SINGLE
      call-site (`put_work_item/2`), and the `@active_states` vocabulary is SHARED with
      selection (`find_active`), supersession and the deadline guard — extracting it
      would force either a duplication of that authority, or a dedicated module for 20 LOC.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.TaskQueue.Broadcast
  alias Fleet.TaskQueue.Store
  alias Fleet.TaskQueue.WorkItem

  # SINGLE AUTHORITY `WorkItem.active_states/0` (the owner of the `state` type) — NOT a 2nd copy of the
  # vocabulary here. Shared with the poller's lock reconciliation (`pod_has_active_task?`, F-C050): both
  # sides agree byte-for-byte on which states OWN a slot/lock. Resolved at compile time (literal list) →
  # usable in the guards below (`s in @active_states`).
  @active_states WorkItem.active_states()

  # Portable-safe ceiling for `Process.send_after/3` (2^32-1 ms ≈ 49.7 days): the historic ERTS timer
  # max, valid on EVERY OTP. A deadline further out (up to the max Elixir DateTime, year 9999 ≈ 8000
  # years, which alone EXCEEDS the ERTS ceiling and would raise `ArgumentError` → GenServer crash) is
  # armed at this ceiling and RE-ARMED when the timer fires — see `maybe_schedule_deadline/1`.
  @max_timer 4_294_967_295
  # Retention bound for terminal tasks (:completed/:failed/:cleared). Without it,
  # `work_items` grows unbounded and `persist/1` rewrites an ever-larger `state.json` on EVERY
  # mutation. We keep the N most recent; the active ones do not count (cf. prune_terminal/2).
  @default_retention_terminal 500

  # Default last-poll TTL (24 h): a live pod polls FAR more often than this (get_for_pod on each work
  # cycle) → this never drops a live pod, only bounds dead-pod-without-clear leakage to ~1 day of churn.
  @default_poll_retention_ms 86_400_000

  # ============================================================
  # Lifecycle
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # `name: nil` → anonymous server (test isolation). Absent → canonical name.
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @impl GenServer
  def init(opts) do
    persist? = Keyword.get(opts, :persist, true)
    state_path = Keyword.get(opts, :state_path, Store.default_path())

    base = %{
      work_items: %{},
      # Last-poll per pod (the agent called get_for_pod = in-band ACK, EVEN with no work item → bootstrap
      # signal "the agent is up + reached out"). In-mem/ephemeral: recency lives at runtime, not
      # persisted (a restart re-establishes it via subsequent polls).
      polls: %{},
      # REPL-up per pod: the pod's MCP socket has received AT LEAST ONE line from it. Distinct from
      # `polls`, and the distinction is the whole point — `polls` proves the agent asked for WORK
      # (it took a turn), this proves only that its client is CONNECTED, which happens at TUI init,
      # before any turn. It is what the kick loop needs: typing into a REPL that is not up yet is
      # not a no-op (tmux buffers the keys and the TUI replays each line as its own submission).
      # Same in-mem/ephemeral nature as `polls`, same purge point (`clear_for_pod`).
      connects: %{},
      state_path: state_path,
      persist: persist?,
      topic: Keyword.get(opts, :topic, Bus.main_topic()),
      # Bus seam (default = the real `Fleet.EventRouter.Bus`). Module with `broadcast/2`. Lets us
      # test the non-swallowed lifecycle path (a stub bus that returns `{:error,_}` / raises on work_item.completed)
      # without touching the global `:persistent_term` registry.
      bus: Keyword.get(opts, :bus, Bus),
      retention_terminal_max:
        Keyword.get(opts, :retention_terminal_max) ||
          Application.get_env(
            :fleet_task_queue,
            :retention_terminal_max,
            @default_retention_terminal
          ),
      # TTL of a per-pod last-poll (in-mem): a pod that has not polled within it is dead → its entry is
      # pruned. Bounds `polls` (record_poll only ADDS, clear_for_pod is the only removal → a pod that
      # crashes WITHOUT a clear would leak its entry forever, unbounded over uptime).
      poll_retention_ms:
        Keyword.get(opts, :poll_retention_ms) ||
          Application.get_env(:fleet_task_queue, :poll_retention_ms, @default_poll_retention_ms)
    }

    case load_state(state_path, persist?) do
      :empty ->
        {:ok, base}

      {:ok, work_items} ->
        {:ok, %{base | work_items: work_items}, {:continue, :reschedule_deadlines}}

      {:corrupt, found} ->
        {:ok, base, {:continue, {:corrupt, found}}}
    end
  end

  @impl GenServer
  def handle_continue(:reschedule_deadlines, state) do
    # Recovery: deadlines are armed only at enqueue. After a restart, we re-arm
    # the ACTIVE tasks; a deadline passed during the downtime → immediate check (→ :"work_item.failed" via
    # handle_info), not active-forever.
    for {_id, %WorkItem{state: s} = t} <- state.work_items, s in @active_states do
      maybe_schedule_deadline(t)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_continue({:corrupt, found}, state) do
    # Non-blocking fallback: empty state + a boot-anomaly event post-init. `found` may carry
    # the non-JSON-encodable {:work_item, id, reason} variant (Store decode) → stringify at
    # the producer so the payload stays JSON-safe end-to-end (WS edge encodes it raw).
    lossy_broadcast(
      state,
      Fleet.Event.new(:task_queue, :"state.corrupt",
        payload: %{expected: 1, found: inspect(found)}
      )
    )

    {:noreply, state}
  end

  # ============================================================
  # Command Port
  # ============================================================

  # CAST, not call: this is written from the pod-socket read loop, on every inbound line. A call
  # would put the broker's mailbox on the critical path of an MCP response — the queue's health
  # would become the pod's latency. Losing one mark costs nothing: the next line re-posts it.
  @impl GenServer
  def handle_cast({:mark_connected, pod_id}, state) do
    {:noreply, %{state | connects: Map.put_new(state.connects, pod_id, true)}}
  end

  @impl GenServer
  def handle_call({:enqueue, pod_id, attrs}, _from, state) do
    # Smart constructor: casts the attrs (deadline ISO→DateTime, metadata=map, …) — a malformed attr
    # is refused with `{:error, {:bad_attr, _}}` instead of storing a semi-typed work item.
    case WorkItem.new(pod_id, attrs) do
      {:error, _} = err ->
        {:reply, err, state}

      {:ok, work_item} ->
        # AXIOM "1 ACTIVE work item/pod" held AT WRITE. A FRESH work item SUPERSEDES EVERY active one of the pod:
        # the `:pending` never pulled (drop) AND the in-flight `:assigned` (→ `:cleared`). A re-brief
        # replaces the old one: the pod will take the new one (the only active left) at the next `get_for_pod`. Uniqueness
        # MUST be held here, not only at read: keeping a stale `:assigned` alongside the new pending
        # would leave it ACTIVE and invisible to the guards (`find_active` = `max_by(enqueued_at)` serves the most recent but
        # MASKS the leak → unbounded "2 actives/pod" state, invariant violated). Uniqueness held AT WRITE →
        # `find_active`/`max_by` becomes moot (at most 1 active/pod by construction).
        {state, superseded} = supersede_active(state, pod_id)

        new_state = state |> put_work_item(work_item) |> persist()

        # Supersede was the ONLY terminal transition with no event: the mandates it closes went
        # `:cleared` behind a debug log, so the audit trail lied by omission about their fate and
        # any consumer holding per-mandate context (StepRunConsumer's `gate_evals`) kept it
        # forever. One `work_item.cleared` per superseded item, SAME shape as the clear_for_pod
        # rail (payload `work_item_id` + `reason` — the reason distinguishes the two paths).
        for t <- superseded do
          Logger.debug("Server: enqueue pod=#{pod_id} supersedes stale active item #{t.id}")

          lossy_broadcast(
            new_state,
            event(:"work_item.cleared", t, %{work_item_id: t.id, reason: :superseded})
          )
        end

        # payload = `%{work_item_id}` (consistent with every other work_item.* event), NOT the raw `%WorkItem{}` —
        # WorkItem has no @derive Jason.Encoder, so a `%{work_item: work_item}` would crash `Jason.encode!`
        # in any JSON-event consumer (Fleet.API.WS on every enqueue). No consumer
        # needs the struct (deck = count, audit = pod_id/correlation_id).
        lossy_broadcast(
          new_state,
          event(:"work_item.enqueued", work_item, %{work_item_id: work_item.id})
        )

        maybe_schedule_deadline(work_item)
        {:reply, {:ok, work_item}, new_state}
    end
  end

  def handle_call({:get_for_pod, pod_id}, _from, state) do
    # last-poll BEFORE the case: the agent reached out = in-band ACK, whether it receives a work item or not
    # (the `:no_work_item` case is the bootstrap signal "the agent is up + armed").
    state = record_poll(state, pod_id)

    case find_active(state.work_items, pod_id) do
      nil ->
        {:reply, {:error, :no_work_item}, state}

      %WorkItem{state: :pending} = work_item ->
        assigned = %{work_item | state: :assigned, assigned_at: now()}
        new_state = state |> put_work_item(assigned) |> persist()

        lossy_broadcast(
          new_state,
          event(:"work_item.assigned", assigned, %{work_item_id: assigned.id})
        )

        {:reply, {:ok, assigned}, new_state}

      %WorkItem{} = work_item ->
        # already :assigned → idempotent (no re-broadcast, no double dispatch)
        {:reply, {:ok, work_item}, state}
    end
  end

  def handle_call({:submit_result, pod_id, result}, _from, state) do
    case find_active(state.work_items, pod_id) do
      nil ->
        if has_completed?(state.work_items, pod_id),
          do: {:reply, {:error, :double_submit_ignored}, state},
          else: {:reply, {:error, :no_active_work_item}, state}

      %WorkItem{} = work_item ->
        case result["work_item_id"] || result[:work_item_id] do
          tid when tid != nil and tid != work_item.id ->
            # correlation_id of the deliverable ≠ the pod's active work item → reject, no mutation. This is the 2nd
            # anti-impersonation lock (the 1st = the capability on the MCP side): even a proven pod can only close
            # EXACTLY its active work item, never "the last active one" of another. The MCP boundary makes the
            # work_item_id MANDATORY on the pod side → this correlator is always present and verified.
            {:reply, {:error, :work_item_id_mismatch}, state}

          _ok ->
            # `work_item_id` removed from the STORED deliverable: it is a transport correlator (proof "I'm closing THIS
            # work item"), not business data of the result. The work item is already identified by `work_item.id`;
            # keeping it in `result` would only duplicate/pollute the broadcast deliverable.
            clean_result = result |> Map.delete("work_item_id") |> Map.delete(:work_item_id)

            completed = %{
              work_item
              | state: :completed,
                completed_at: now(),
                result: clean_result
            }

            # additive role/issue_id: KEPT for consumers outside this tree — the Bus feeds the
            # no-auth WS surface, whose external readers correlate on the origin agent's identity.
            # No in-tree module reads these keys; existing consumers ignore the extra keys.
            # additive `metadata`: the work_item.completed verdict carries the TASK's metadata (which
            # survives in the broker across a crash of the StepRunConsumer alone). For a gatekeeper eval it carries the
            # resumption context (`gate_eval`/`payload`/`pipeline`/…) → the restarted StepRunConsumer (gate_evals
            # RAM empty) RECONSTRUCTS the eval_ctx from the metadata instead of a silent `{:noreply}` (wedge for life).
            ev =
              event(:"work_item.completed", completed, %{
                work_item_id: completed.id,
                role: completed.role,
                issue_id: completed.issue_id,
                result: clean_result,
                metadata: completed.metadata
              })

            # BROADCAST BEFORE COMMIT (CI-03). `work_item.completed` is LIFECYCLE load-bearing (the double-hop
            # STARTS here: the pod consumes it in `:monitoring` → `pod.completed` → StepRunConsumer). The terminal
            # `:completed` state is committed ONLY after the delivery is confirmed — same ordering doctrine as
            # `StepRunCompleter` (lock lifted LAST) and the Pod (`pod.completed` re-emitted until it passes). On
            # failure NOTHING is committed: the item STAYS active (`:assigned`) → `find_active`
            # returns it → a re-submit RE-PLAYS honestly (re-broadcast), and the pod is never lied to with a
            # `:double_submit_ignored`/"already received" on an UNdelivered item. Pre-CI-03 the commit was done
            # first, so a lost broadcast left a terminal `:completed` + a false success at retry.
            #
            # INVARIANT this rests on: `required_broadcast {:error} ⟺ ZERO subscriber delivered`. True on the
            # current mono-node Phoenix.PubSub (both failure modes are pre-dispatch, all-or-nothing:
            # `{:error,_}` adapter-unreachable, or `UnregisteredError` raised by `assert_authorized!` BEFORE any
            # dispatch — cf. `Broadcast.required`). So an item stays active only if NOBODY received → re-emission
            # never double-delivers. A future clustered/async Bus (partial delivery before error) would break it.
            # Across-restart durability stays the forge reconciliation (F-C050), NOT this ephemeral broker.
            case required_broadcast(state, ev) do
              :ok ->
                new_state = state |> put_work_item(completed) |> persist()
                {:reply, {:ok, completed}, new_state}

              {:error, _} = err ->
                {:reply, err, state}
            end
        end
    end
  end

  # Purges ALL of the pod's active items (not only the most recent via `find_active`). With the
  # "1 active/pod" invariant held at enqueue (`supersede_active`), there is normally only one; but a clear must
  # stay TOTAL (no residual stale `:assigned` that would escape the clear and leak — symmetric to
  # the enqueue). One `:"work_item.cleared"` broadcast per cleared task; no active → idempotent no-op.
  def handle_call({:clear_for_pod, pod_id}, _from, state) do
    # The clear decommissions the pod → we ALSO drop its last-poll from `state.polls` (symmetric to
    # the `work_items` purge below). Without this, `polls` (one timestamp per pod, NEVER persisted) accumulates
    # dead pod_ids indefinitely: `record_poll` only adds entries, and `prune_terminal` only prunes
    # `work_items`. `clear_for_pod` is the pod's canonical purge point → this is where a poll becomes
    # obsolete. `Map.delete` idempotent: no-op if the pod never polled or has no active item.
    state = %{
      state
      | polls: Map.delete(state.polls, pod_id),
        connects: Map.delete(state.connects, pod_id)
    }

    active =
      state.work_items
      |> Map.values()
      |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))

    case active do
      [] ->
        {:reply, :ok, state}

      work_items ->
        cleared = Enum.map(work_items, &%{&1 | state: :cleared})
        new_state = Enum.reduce(cleared, state, &put_work_item(&2, &1)) |> persist()

        for t <- cleared,
            do:
              lossy_broadcast(
                new_state,
                event(:"work_item.cleared", t, %{work_item_id: t.id})
              )

        {:reply, :ok, new_state}
    end
  end

  # ============================================================
  # Query Port (no side-effect, no broadcast)
  # ============================================================

  def handle_call(:list_pending, _from, state) do
    pending = state.work_items |> Map.values() |> Enum.filter(&(&1.state == :pending))
    {:reply, pending, state}
  end

  # Active = `@active_states` (the SAME authority as supersede/deadline — not a 2nd state
  # vocabulary). Consumed by the poller's lock reconciliation: a brick under an ACTIVE
  # gatekeeper eval is owned (metadata `gate_eval`); a `:cleared` (superseded) or
  # `:completed` eval no longer is → orphan reclaim takes over.
  def handle_call(:list_active, _from, state) do
    active = state.work_items |> Map.values() |> Enum.filter(&(&1.state in @active_states))
    {:reply, active, state}
  end

  def handle_call({:pod_status, pod_id}, _from, state) do
    status =
      case latest_for_pod(state.work_items, pod_id) do
        nil -> nil
        %WorkItem{state: s} -> s
      end

    {:reply, {:ok, status}, state}
  end

  # SLOT-FREEZE: issue of the pod's LAST task, WHATEVER its state — this query does no state
  # filtering. Its consumer (the poller's lock reconciliation) pre-filters pods on
  # `pod_has_active_task?` (F-C050), so only a pod with an ACTIVE task reaches this query. The
  # publication window (submit → :completed → push) is covered by the reconciliation's 2-tick
  # grace + the idempotence of the completion sequence, NOT by this query returning terminal tasks.
  def handle_call({:pod_active_issue_id, pod_id}, _from, state) do
    issue =
      case latest_for_pod(state.work_items, pod_id) do
        nil -> nil
        %WorkItem{issue_id: t} -> t
      end

    {:reply, {:ok, issue}, state}
  end

  # Pod last-poll (`DateTime | nil`) = the bootstrap in-band ACK ("the agent reached out",
  # even with no work item). The real consumer (`Pod.TaskProbe.polled?`) tests PRESENCE (!= nil),
  # it does NOT compare instants (if a recency comparison is ever introduced, do it in
  # monotonic/token, never DateTime-vs-DateTime — NTP jumps).
  def handle_call({:last_poll, pod_id}, _from, state) do
    {:reply, Map.get(state.polls, pod_id), state}
  end

  def handle_call({:connected?, pod_id}, _from, state) do
    {:reply, Map.has_key?(state.connects, pod_id), state}
  end

  # ============================================================
  # Deadline (transition :failed)
  # ============================================================

  @impl GenServer
  def handle_info({:check_deadline, work_item_id}, state) do
    case Map.get(state.work_items, work_item_id) do
      %WorkItem{state: s} = work_item when s in @active_states ->
        if deadline_reached?(work_item) do
          failed = %{work_item | state: :failed}
          new_state = state |> put_work_item(failed) |> persist()

          # `:"work_item.failed"` (deadline) = watchdog of the IRREDUCIBLE, not a caller-facing
          # completion: lossy broadcast (a handle_info has no caller to propagate to). The :failed
          # transition is already recorded + persisted above — a lost broadcast costs observability
          # only, logged warning by `Broadcast`. The guard stays, honest.
          lossy_broadcast(
            new_state,
            event(:"work_item.failed", failed, %{
              work_item_id: failed.id,
              reason: :deadline_expired
            })
          )

          {:noreply, new_state}
        else
          # Timer fired EARLY: the deadline was beyond the send_after ceiling → armed at @max_timer, not
          # actually reached yet. Re-arm for the remainder; NEVER fail a still-valid item on a clamped tick.
          maybe_schedule_deadline(work_item)
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================
  # Helpers — selection
  # ============================================================

  defp find_active(work_items, pod_id) do
    work_items
    |> Map.values()
    |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))
    |> Enum.max_by(& &1.enqueued_at, DateTime, fn -> nil end)
  end

  defp latest_for_pod(work_items, pod_id) do
    work_items
    |> Map.values()
    |> Enum.filter(&(&1.pod_id == pod_id))
    |> Enum.max_by(& &1.enqueued_at, DateTime, fn -> nil end)
  end

  # Supersedes EVERY active item of the pod (a fresh work item at enqueue replaces the old one): each active
  # (`:pending` | `:assigned`) is transitioned to `:cleared` — including the `:pending`
  # never pulled (SAME transition as the others, it stays traceable in the map; nothing is dropped).
  # The pod abandons the old one: `submit_result` of the old work item will hit `find_active`
  # = nil → `:no_active_work_item`/`:double_submit_ignored`, never a mutation of the new one. Keeps all the rest
  # (other pods, the pod's terminal items). Bounds the queue to 1 active/pod AT WRITE. Returns
  # `{state, superseded_items}` — the ITEMS, not a count: the caller broadcasts one
  # `work_item.cleared` per item (a terminal transition with no event is a hole in the audit
  # trail, and it strands the per-mandate context consumers hold — cf. StepRunConsumer gate_evals).
  defp supersede_active(state, pod_id) do
    superseded =
      state.work_items
      |> Map.values()
      |> Enum.filter(&(&1.pod_id == pod_id and &1.state in @active_states))
      |> Enum.map(&%{&1 | state: :cleared})

    work_items =
      Enum.reduce(superseded, state.work_items, fn t, acc -> Map.put(acc, t.id, t) end)

    {%{state | work_items: work_items}, superseded}
  end

  defp has_completed?(work_items, pod_id) do
    Enum.any?(Map.values(work_items), &(&1.pod_id == pod_id and &1.state == :completed))
  end

  defp record_poll(state, pod_id) when is_binary(pod_id) do
    now = now()

    # Prune stale polls on each activity (bounds `polls` — see @default_poll_retention_ms), then record.
    polls = state.polls |> prune_stale_polls(now, state.poll_retention_ms) |> Map.put(pod_id, now)
    %{state | polls: polls}
  end

  defp prune_stale_polls(polls, now, ttl_ms) do
    cutoff = DateTime.add(now, -ttl_ms, :millisecond)
    Map.reject(polls, fn {_pod, ts} -> DateTime.compare(ts, cutoff) == :lt end)
  end

  defp put_work_item(state, %WorkItem{} = work_item) do
    work_items = Map.put(state.work_items, work_item.id, work_item)
    %{state | work_items: prune_terminal(work_items, state.retention_terminal_max)}
  end

  # Keeps at most `max` TERMINAL tasks (the most recent), prunes the oldest.
  # No-op as long as we are under the cap. ACTIVE tasks do not count and are NEVER cut
  # (in-flight work items). The recency order (≠ enqueue order) protects double-submit detection:
  # a just-completed task is the most recent → never pruned first (has_completed?/1).
  defp prune_terminal(work_items, max) do
    terminal = for {_id, t} <- work_items, t.state not in @active_states, do: t

    if length(terminal) <= max do
      work_items
    else
      drop_ids =
        terminal
        |> Enum.sort_by(&recency/1, {:desc, DateTime})
        |> Enum.drop(max)
        |> MapSet.new(& &1.id)

      Map.reject(work_items, fn {id, _t} -> MapSet.member?(drop_ids, id) end)
    end
  end

  # Recency for the retention order: completed_at if completed, else assigned_at, else
  # enqueued_at (always present — @enforce_keys). Always a %DateTime{}, never nil.
  defp recency(%WorkItem{} = t), do: t.completed_at || t.assigned_at || t.enqueued_at

  defp maybe_schedule_deadline(%WorkItem{deadline: %DateTime{} = dl, id: id}) do
    ms = DateTime.diff(dl, DateTime.utc_now(), :millisecond)

    cond do
      # deadline ALREADY passed (e.g. at recovery): immediate check → fail via handle_info, instead of
      # ignoring it silently (= task active forever).
      ms <= 0 ->
        send(self(), {:check_deadline, id})

      # Beyond the ERTS `send_after` ceiling: arm at @max_timer; the handler re-checks the REAL deadline
      # and re-arms for the remainder. Without this clamp, a far-future deadline raised `ArgumentError`
      # here → crash of the TaskQueue GenServer (at enqueue AND at recovery re-arm on boot).
      ms > @max_timer ->
        Process.send_after(self(), {:check_deadline, id}, @max_timer)

      true ->
        Process.send_after(self(), {:check_deadline, id}, ms)
    end

    :ok
  end

  defp maybe_schedule_deadline(_), do: :ok

  # now >= deadline. The check_deadline timer can fire EARLY (a far-future deadline is clamped to
  # @max_timer), so the handler MUST re-verify the real deadline rather than assume expiry on tick.
  defp deadline_reached?(%WorkItem{deadline: %DateTime{} = dl}),
    do: DateTime.compare(DateTime.utc_now(), dl) != :lt

  defp deadline_reached?(_), do: false

  # ============================================================
  # Helpers — events (policy in Fleet.TaskQueue.Broadcast)
  # ============================================================
  #
  # One-line adapters: the GenServer state does NOT traverse the policy module —
  # here we unpack the per-instance seams (`state.bus`, `state.topic`) and pass
  # explicit arguments. The load-bearing vs lossy-observability classification (the WHY
  # of the two regimes) lives in the moduledoc of `Fleet.TaskQueue.Broadcast`.

  defp event(type, %WorkItem{} = work_item, payload),
    do: Broadcast.event(type, work_item, payload)

  defp lossy_broadcast(state, %Fleet.Event{} = ev),
    do: Broadcast.lossy(state.bus, state.topic, ev)

  defp required_broadcast(state, %Fleet.Event{} = ev),
    do: Broadcast.required(state.bus, state.topic, ev)

  defp now, do: DateTime.utc_now()

  # ============================================================
  # Helpers — persistence (serialization + FS in Fleet.TaskQueue.Store)
  # ============================================================
  #
  # The Server keeps the ORCHESTRATION (do we persist? do we reload?) — the decisions
  # depend on its boot options (`persist: false` = ephemeral prod mode,
  # `state_path: nil`). Store only knows the file format.

  defp persist(%{persist: false} = state), do: state
  defp persist(%{state_path: nil} = state), do: state

  defp persist(%{state_path: path, work_items: work_items} = state) do
    Store.save(path, work_items)
    state
  end

  defp load_state(_path, false), do: :empty
  defp load_state(nil, _persist), do: :empty
  defp load_state(path, true), do: Store.load(path)
end
