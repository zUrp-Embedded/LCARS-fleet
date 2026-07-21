defmodule Fleet.Spawner.Pod.Publishing do
  @moduledoc """
  The `:publishing` FLAG (SLOT-FREEZE) of a pod pipe + its `:publish_deadline` fail-safe — a cluster
  extracted from `Fleet.Spawner.Pod`.

  A `git_native` pipe is `:publishing` between the submit of its result and the forge confirmation
  `deliverable.published`: while it is publishing, it is NOT `:ready` (no reset/re-brief — the async
  push must have READ the workspace before we reset it). `:publishing` is a FLAG in `data.conditions`,
  NOT a gen_statem state: a publishing pod is functionally in `:monitoring` (it can receive a task);
  the flag only gates the EXTERNAL reset/re-brief (`pipe_rebrief_state` reads `pod_info.conditions`).

  This module carries the WHOLE lifecycle of the flag and of its single timer (the generic timeout
  `:publish_deadline`, a fail-safe if the forge confirmation never arrives): the entry decision (gated
  on `deliverable_mode == "git_native"` — a payload pod has nothing to protect and so never arms a
  deadline that is never lifted), the lift, the predicate, the cancel action and the delay config. No
  own state, no Port, no ARMED timer here: the functions return VALUES (transformed `data` +
  gen_statem actions) that the `Pod` emits — the HANDLERS (`:info deliverable.published`,
  `{:timeout, :publish_deadline}`) stay callbacks of the machine.

  ## Contract (called by `Pod`)

  - `maybe_enter_publishing/1` — called by `do_extract_proceed` on the return to `:monitoring` of a
    long-lived pod; returns `{data, actions}` (flag set + arming of the deadline, or identity).
  - `leave_publishing/1` / `cancel_publish_deadline_action/0` — called by the 2 lift handlers
    (`deliverable.published` received, or fire of `:publish_deadline`).
  - `publishing?/1` — is the flag set? (gate for the lift logs on the handler side).
  - `publish_deadline_ms/0` — the fail-safe delay (config `:fleet_spawner, :publish_deadline_ms`,
    default 120_000 ms).

  Depends on `Fleet.CapProfile.deliverable_mode/1` (single source of the deliverable mode); no
  dependency toward `Fleet.Spawner.Pod` (no cycle).

  **Last revised**: 2026-07-21
  """

  @doc """
  Enters `:publishing` IF the pod has an async git deliverable to protect. Only a pod with a
  `git_native` deliverable has a push (confirmed by `deliverable.published`) that must be protected
  from reset/re-brief → flag + arming of the generic timeout `:publish_deadline`. A payload pod
  (gatekeeper/architect: no push) has nothing to protect; putting it `:publishing` would arm a
  deadline that is never lifted → recurring WARNING + false semantics. Returns `{data, actions}` —
  the `Pod` emits the actions on its transition back to `:monitoring`.
  """
  @spec maybe_enter_publishing(map()) :: {map(), [:gen_statem.action()]}
  def maybe_enter_publishing(data) do
    if Fleet.CapProfile.deliverable_mode(data.cap_profile) == "git_native" do
      {put_flag(data), [{{:timeout, :publish_deadline}, publish_deadline_ms(), :fire}]}
    else
      {data, []}
    end
  end

  @doc """
  Lifts the `:publishing` flag (the pod becomes `:ready` again). Called on `deliverable.published`
  received OR on the fire of `:publish_deadline` (fail-safe). The timer cancellation is emitted as an
  ACTION by the callers (`cancel_publish_deadline_action/0`), not here.
  """
  @spec leave_publishing(map()) :: map()
  def leave_publishing(data),
    do: Map.update!(data, :conditions, &MapSet.delete(&1, :publishing))

  @doc """
  Is the `:publishing` flag set? Gate for the lift logs on the handler side (a lift by deadline must
  be visible, a lift of a flag that was never set does not log).
  """
  @spec publishing?(map()) :: boolean()
  def publishing?(data), do: MapSet.member?(data.conditions, :publishing)

  @doc """
  gen_statem action that cancels the generic timeout `:publish_deadline` (= setting it to
  `:infinity`). Emitted by the 2 lift handlers.
  """
  @spec cancel_publish_deadline_action() :: :gen_statem.action()
  def cancel_publish_deadline_action, do: {{:timeout, :publish_deadline}, :infinity, :fire}

  @doc """
  The `:publish_deadline` fail-safe delay (ms) — config `:fleet_spawner, :publish_deadline_ms`,
  default 120_000. Past this delay with no `deliverable.published`, the flag is lifted anyway
  (otherwise the pod would stay never-`:ready` hence never re-briefed — a wedge), with a WARNING on
  the handler side.

  WHY THE LIFT IS ASSERTED SAFE, AND WHY THAT ASSERTION DOES NOT HOLD AS WRITTEN. Clearing the flag
  re-enables the workspace reset, so it must not fire while the pilot is still reading the workspace.
  The argument was: the read — `StepRunCompleter` → `Fleet.Workflow.Deliverable.publish` — is spawned
  CONCURRENTLY on `pod.completed` (no queue) and each git op is hard-bounded + SIGKILL-enforced, for a
  worst-case serial under this 120_000 deadline.

  The bound was counted wrong — twice. `publish` chains SEVEN bounded git ops on the git_native path
  (the ONLY path that arms this deadline — `maybe_enter_publishing` gates on `git_native`), not three,
  and the count omitted BOTH `materialize_content`'s own HEAD read AND `DeliverableGate.verify` — the
  latter carrying a THIRD timeout knob the argument never mentions, its own `@git_timeout_ms` (15_000,
  a module attribute, not config):

      materialize_content  (head_advanced → read_head_sha)  :fleet_workflow, :git_local_timeout_ms   30_000
      Git.ancestor?        (verify)                         :fleet_workflow, :git_local_timeout_ms   30_000
      check_identity       (verify)                         DeliverableGate @git_timeout_ms          15_000
      maybe_check_trailer  (verify)                         DeliverableGate @git_timeout_ms          15_000
      scan_secrets         (verify)                         DeliverableGate @git_timeout_ms          15_000
      head_sha                                              :fleet_workflow, :git_local_timeout_ms   30_000
      push_deliverable                                      :fleet_workflow, :git_push_timeout_ms    30_000
                                                                                                    -------
                                                                                                    165_000

  165s against a 120_000 deadline — 150s without the role trailer, still over. (`materialize_content`'s
  HEAD read at `publish/1` is a DISTINCT `read_head_sha` from the later `head_sha` op; on the `:payload`
  path it is a commit instead, but that path never arms this deadline.) And that is still a floor: it
  excludes the `--force-with-lease` branch of the push. So the lift is NOT established safe by this
  reasoning; it is asserted.

  What is NOT established either is that the race bites: nobody has shown the reset actually landing on
  a live git process. Do not read the numbers above as a bug report — read them as: this invariant is
  unproven in both directions, and the timing argument is the wrong instrument. The pod cannot observe
  the publisher (different domain, Spawner ∌ Pilot; the flag is the only channel), which is why a
  budget comparison stands in for a fact. The side that PERFORMS the reset is Pilot, and it does hold
  that fact — `StepRunConsumer.inflight_completions/0` counts the live completion Tasks. Wiring those
  two is what would replace arithmetic with observation.
  """
  @spec publish_deadline_ms() :: non_neg_integer()
  def publish_deadline_ms,
    do: Application.get_env(:fleet_spawner, :publish_deadline_ms, 120_000)

  # Sets the flag in data.conditions. Local MapSet primitive: `add_condition/2` (Pod) stays the
  # accumulator of the machine's milestones; here we touch ONLY :publishing.
  defp put_flag(data),
    do: Map.update!(data, :conditions, &MapSet.put(&1, :publishing))
end
