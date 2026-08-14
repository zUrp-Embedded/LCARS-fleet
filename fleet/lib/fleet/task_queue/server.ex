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

  ⚠ **`required` is about THIS server's obligation, not about delivery.** Its `:ok` proves the bus
  accepted the message; zero subscriber is also `:ok`, so a completion CAN be committed terminal
  with nobody left to advance the step_run. The broker cannot close that gap from here — the probe
  would have to ask the SPAWNER whether this item's pod still listens, and the spawner is this
  domain's source, not its dependency. `Fleet.TaskQueue.Broadcast` states the full reasoning; the
  durable half of completion is the forge reconciliation (F-C050), never this ephemeral broker.

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

  # F-C050
  @active_states WorkItem.active_states()

  @max_timer 4_294_967_295
  @default_retention_terminal 500
  @default_poll_retention_ms 86_400_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
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
            :lcars_fleet,
            :task_queue_retention_terminal_max,
            @default_retention_terminal
          ),
      poll_retention_ms:
        Keyword.get(opts, :poll_retention_ms) ||
          Application.get_env(
            :lcars_fleet,
            :task_queue_poll_retention_ms,
            @default_poll_retention_ms
          )
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
    for {_id, %WorkItem{state: s} = t} <- state.work_items, s in @active_states do
      maybe_schedule_deadline(t)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_continue({:corrupt, found}, state) do
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

        lossy_broadcast(
          new_state,
          event(:"work_item.enqueued", work_item, %{work_item_id: work_item.id})
        )

        maybe_schedule_deadline(work_item)
        {:reply, {:ok, work_item}, new_state}
    end
  end

  def handle_call({:get_for_pod, pod_id}, _from, state) do
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
        if completed_submit?(state.work_items, pod_id, result),
          do: {:reply, {:error, :double_submit_ignored}, state},
          else: {:reply, {:error, :no_active_work_item}, state}

      %WorkItem{} = work_item ->
        case result["work_item_id"] || result[:work_item_id] do
          tid when tid != nil and tid != work_item.id ->
            {:reply, {:error, :work_item_id_mismatch}, state}

          # A MANDATE IS NOT CLOSABLE BEFORE IT IS READ, and until now that held by accident.
          #
          # `@active_states` is `[:pending, :assigned]`, so this branch accepted a `:pending` item —
          # one the pod never pulled. Nothing exploited it, for a reason that is not a rule: the id
          # is only obtainable through `get_work_item`, which transitions the item to `:assigned` on
          # its way out. The guarantee "the pod saw the brief before closing it" was therefore a
          # property of who knows an id, not of the state machine. A confused pod, a misplaced retry
          # or a future caller holding an id another way would each turn it off silently.
          #
          # The distinction already exists in the codebase — `Poller.Reconciliation` keys its own
          # ownership rule on `@pulled_states [:assigned]` for exactly this reason. Applying it here
          # is consistency, not a new invention.
          #
          # AFTER the id check and not before, deliberately: a stale id submitted while a pending
          # item is active must still answer `:work_item_id_mismatch`, which names the real problem.
          # Refusing on the state first would report "not pulled" about a mandate the pod never
          # meant to close — an instrument answering the neighbouring question.
          _ok when work_item.state == :pending ->
            {:reply, {:error, :work_item_not_pulled}, state}

          _ok ->
            clean_result = result |> Map.delete("work_item_id") |> Map.delete(:work_item_id)

            completed = %{
              work_item
              | state: :completed,
                completed_at: now(),
                result: clean_result
            }

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
            # ⚠ THE SYMBOL USED TO BE `⟺`, AND THAT BICONDITIONAL IS FALSE IN THE DIRECTION THAT
            # MATTERS: zero subscriber yields `:ok`, not an error. What the discipline needs is only
            # the implication below — a refusal proves nobody got it — and reading it as an
            # equivalence turns "the bus accepted" into "a consumer received", which nothing here
            # establishes (cf. `Broadcast.required`, which now states what `:ok` does not buy).
            # INVARIANT this rests on: `required_broadcast {:error} ⟹ ZERO subscriber delivered`. True on the
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

  def handle_call(:list_pending, _from, state) do
    pending = state.work_items |> Map.values() |> Enum.filter(&(&1.state == :pending))
    {:reply, pending, state}
  end

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

          lossy_broadcast(
            new_state,
            event(:"work_item.failed", failed, %{
              work_item_id: failed.id,
              reason: :deadline_expired
            })
          )

          {:noreply, new_state}
        else
          maybe_schedule_deadline(work_item)
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

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

  # "HAS THIS MANDATE ALREADY BEEN RECEIVED?" — not "has this pod ever completed anything".
  #
  # The difference is the whole point, because the answer is told to the pod as a SUCCESS: the MCP
  # layer turns `:double_submit_ignored` into `{:ok, "Result already received (ignored)."}`. Answer
  # the neighbouring question and a pod is told its work landed when it went in the bin.
  #
  # The sequence that produced it, and none of its steps is exotic: the pod completes mandate A, a
  # mandate B is enqueued, a teardown clears B, and B's `submit_result` — already in flight on the
  # socket — arrives. `find_active` is nil, the old predicate saw A, and B's result was dropped
  # under an acknowledgement. The `work_item_id_mismatch` guard could not catch it either: it only
  # runs on the branch where an ACTIVE item exists, so on this path the submitted id was never
  # compared to anything.
  #
  # Correlating by id also states the honest answer when there is nothing to correlate: no id, or
  # an id we never completed, is `:no_active_work_item` — "we have nothing of yours", which is
  # true — and never "already received", which would be a claim we cannot support.
  defp completed_submit?(work_items, pod_id, result) do
    case result["work_item_id"] || result[:work_item_id] do
      nil ->
        false

      id ->
        case Map.get(work_items, id) do
          %WorkItem{pod_id: ^pod_id, state: :completed} -> true
          _ -> false
        end
    end
  end

  defp record_poll(state, pod_id) when is_binary(pod_id) do
    now = now()

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

  defp recency(%WorkItem{} = t), do: t.completed_at || t.assigned_at || t.enqueued_at

  defp maybe_schedule_deadline(%WorkItem{deadline: %DateTime{} = dl, id: id}) do
    ms = DateTime.diff(dl, DateTime.utc_now(), :millisecond)

    cond do
      ms <= 0 ->
        send(self(), {:check_deadline, id})

      ms > @max_timer ->
        Process.send_after(self(), {:check_deadline, id}, @max_timer)

      true ->
        Process.send_after(self(), {:check_deadline, id}, ms)
    end

    :ok
  end

  defp maybe_schedule_deadline(_), do: :ok

  defp deadline_reached?(%WorkItem{deadline: %DateTime{} = dl}),
    do: DateTime.compare(DateTime.utc_now(), dl) != :lt

  defp deadline_reached?(_), do: false

  defp event(type, %WorkItem{} = work_item, payload),
    do: Broadcast.event(type, work_item, payload)

  defp lossy_broadcast(state, %Fleet.Event{} = ev),
    do: Broadcast.lossy(state.bus, state.topic, ev)

  defp required_broadcast(state, %Fleet.Event{} = ev),
    do: Broadcast.required(state.bus, state.topic, ev)

  defp now, do: DateTime.utc_now()

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
