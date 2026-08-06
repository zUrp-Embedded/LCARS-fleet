defmodule Fleet.Spawner.Pod.TaskProbe do
  @moduledoc """
  PROBES of task/agent state via `Fleet.TaskQueue` — cluster extracted from `Fleet.Spawner.Pod`.

  Four broker questions that the `Pod` core (kick handler, response deadline, brief
  enqueue) asks in order to DECIDE, without ever holding state or a timer — on a broker hiccup each
  probe degrades to its documented SAFE default instead of crashing:

  - `polled?/1` — has the agent already called `get_work_item` (real in-band ACK, `last_poll`)? Stops the
    bootstrap kick as soon as the REPL responds. Takes the `state` (reads `state.pod_id`).
  - `pod_has_active_task?/1` — does the pod have an ACTIVE task (`pending|assigned`) here,
    right now? Reporting boolean (`pod_info`) ONLY — the `:result_deadline` fire uses
    `active_task_state/1` (3-state: the boolean conflates idle and unknown).
  - `brief_pulled?/1` — is the brief already pulled (`assigned|completed`)? Stops the wake loop.
  - `no_pending_brief?/1` — NO brief pending (`{:ok, nil}`, never enqueued)? Distinguishes the
    permanent/interactive pod (bootstrap) from the worker (brief `pending` at spawn).

  The last three take the `pod_id` (string); all read `Fleet.TaskQueue.pod_status/last_poll`
  behind a `rescue`/`catch :exit` guard that returns `false` — a broker hiccup (down/restarting,
  GenServer.call that EXITs) must NOT crash the pod. No own state, no Port, no timer, no
  FS write: read-only probes whose failures collapse to safe defaults (never a crash — each
  docstring says which default and why it is safe). The `Pod` passes `pod_id`/`state` as arguments — the module never
  calls back into any `Pod` private. Depends on `Fleet.TaskQueue` (already an app dep); no dependency
  on `Fleet.Spawner.Pod` (no cycle). These probes do not log (no `Logger`): they decide,
  the `Pod` core traces.

  ## Contract (called by `Pod` / `Pod.Brief`)

  - `polled?/1` — bootstrap-stop of the kick (handler `handle_event({:timeout, :kick}, {:attempt, n}, ...)`).
  - `pod_has_active_task?/1` — the `pod_info` reporting boolean ONLY (its own docstring explains
    why the boolean is the WRONG shape at deadline-fire time).
  - `active_task_state/1` — the `:result_deadline` fire decision (3-state: `:active|:idle|:unknown`,
    fail-closed on `:unknown`).
  - `brief_pulled?/1` — reduced to the boolean passed to `Kick.acked?/3` by the handler.
  - `no_pending_brief?/1` — bootstrap detection (handler) + gate of `maybe_enqueue_brief` (`Pod.Brief`).
  - `brief_slot/1` — enqueue-by-slot decision (`Pod.Brief`, 3-state `:free|:occupied|:unknown`).

  **Last revised**: 2026-08-04
  """

  @doc """
  Has the agent POLLED (called get_work_item)? = REAL in-band ACK: the agent reached out via
  the official API (`last_poll`, tracked by the TaskQueue), not a host-side proxy like a
  `pgrep watch.sh` ("the process exists" ≠ "the agent is acting"). Used to stop the bootstrap kick
  as soon as the agent is up. Takes the `state` (reads `state.pod_id`); broker hiccup → `false`.
  """
  @spec polled?(term()) :: boolean()
  def polled?(%{pod_id: pod_id}) when is_binary(pod_id) do
    Fleet.TaskQueue.last_poll(pod_id) != nil
  rescue
    _ -> false
  catch
    # `last_poll` is a GenServer.call → TaskQueue down/restarting EXITs (does not raise), `rescue` does
    # not catch it. SAME guard as brief_pulled?/no_pending_brief?: a broker hiccup does NOT crash the pod.
    :exit, _ -> false
  end

  def polled?(_), do: false

  @doc """
  The pod's REPL is UP: its MCP client has spoken on the pod socket at least once.

  Strictly weaker than `polled?/1` — connecting is not taking a turn — and that is the point. It
  is the only in-band signal available DURING a cold start, which is exactly the window where the
  kick loop must not type: tmux buffers keys sent to a REPL that has not started, and the TUI
  replays every buffered line as its own submission.

  Same defensive shape as the other probes: a broker hiccup answers `false`, i.e. "not proven up",
  which costs one more wait and never a spurious keystroke.
  """
  @spec repl_up?(String.t()) :: boolean()
  def repl_up?(pod_id) when is_binary(pod_id) do
    Fleet.TaskQueue.connected?(pod_id)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def repl_up?(_), do: false

  # pod_status guard: a broker hiccup (down/restart, GenServer.call that EXITs) yields `:error`
  # instead of crashing — since `:error` matches no `{:ok, _}`, each probe falls back to `false`
  # (same truth table as the former inline rescue/catch). Single source of the 3 pod_status probes
  # below; `polled?` does NOT use this helper (it reads `last_poll`, with its own guard).
  defp safe_pod_status(pod_id) do
    Fleet.TaskQueue.pod_status(pod_id)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  @doc """
  Does the pod have an ACTIVE task (`pending`/`assigned`) here, right now?
  REPORTING boolean, consumed by `pod_info` alone. NOT the `:result_deadline` fire probe:
  a boolean is the WRONG shape there (it conflates "idle, let it lapse" with
  "broker unknown, don't act on ignorance"); the fire reads `active_task_state/1` (3-state,
  fail-closed on `:unknown`). Same source as `brief_pulled?`/`no_pending_brief?`
  (`TaskQueue.pod_status` via `safe_pod_status`).
  """
  @spec pod_has_active_task?(String.t()) :: boolean()
  def pod_has_active_task?(pod_id),
    do: match?({:ok, s} when s in [:pending, :assigned], safe_pod_status(pod_id))

  @doc """
  3-STATE version of `pod_has_active_task?` for the `:result_deadline` fire. The boolean
  version CONFLATES `:error` (broker unreachable) into `false` (= idle), which is safe for a
  *reporting* field but WRONG at the deadline fire: a hung pod whose broker blips at the exact fire
  moment would be classed "idle" → the deadline lapses (never re-armed unless the pod MOVES, which a
  hung pod does not) → orphan. So we distinguish:
    * `:active`  → a real response timeout (pending/assigned) → KILL;
    * `:idle`    → genuinely between tasks → let the deadline lapse (no idle-kill);
    * `:unknown` → broker unverifiable → NEITHER (no-kill preserved) but RE-ARM, never lapse.
  Same 3-state fail-closed shape as `brief_slot/1`.
  """
  @spec active_task_state(String.t()) :: :active | :idle | :unknown
  def active_task_state(pod_id) do
    case safe_pod_status(pod_id) do
      {:ok, s} when s in [:pending, :assigned] -> :active
      {:ok, _} -> :idle
      :error -> :unknown
    end
  end

  @doc """
  Is the brief already pulled by the pod? "Pull" = the task is in a state that PROVES that
  Claude has called get_work_item: `:assigned | :completed`. Deliberately NOT:
  `:pending`/`nil` (not yet pulled / not yet enqueued — we keep kicking, which also covers
  the spawn↔enqueue race), nor `:cleared`/`:failed` (deliberate kill / broker deadline — the pod
  has pulled nothing, do NOT stop the kick on a false "pull"; worst case we kick up to the cap,
  harmless, the result_deadline covers it). Broker exception/exit → `false` = "not pulled yet"
  (safe default: the kick loop simply retries at the next attempt). Used to STOP the loop.
  """
  @spec brief_pulled?(String.t()) :: boolean()
  def brief_pulled?(pod_id),
    do: match?({:ok, s} when s in [:assigned, :completed], safe_pod_status(pod_id))

  @doc """
  NO brief (task) pending for this pod: `pod_status == {:ok, nil}` (never enqueued).
  Distinguishes the permanent/interactive pod (nothing to pull cold → bootstrap) from the worker (brief
  `pending` enqueued at spawn). On error → `false` (safe default: we treat it as a
  worker, frequent kick — we do not mistakenly suspend the kicks of a real brief).
  """
  @spec no_pending_brief?(String.t()) :: boolean()
  def no_pending_brief?(pod_id),
    do: match?({:ok, nil}, safe_pod_status(pod_id))

  @doc """
  3-state brief slot, for the ENQUEUE gate (`Brief.maybe_enqueue_brief`) which must NOT conflate the
  two `no_pending_brief? == false` causes: `:free` (`{:ok, nil}`, never enqueued → enqueue), `:occupied`
  (`{:ok, _}`, a brief is already pending → genuine skip), `:unknown` (broker unreachable → the caller
  cannot verify; it still skips to avoid a double-enqueue, but LOUDLY — a dropped admin.spawn brief leaves
  the pod idle). The probe itself stays log-free (by design); the caller decides what to log.
  """
  @spec brief_slot(String.t()) :: :free | :occupied | :unknown
  def brief_slot(pod_id) do
    case safe_pod_status(pod_id) do
      {:ok, nil} -> :free
      {:ok, _} -> :occupied
      :error -> :unknown
    end
  end
end
