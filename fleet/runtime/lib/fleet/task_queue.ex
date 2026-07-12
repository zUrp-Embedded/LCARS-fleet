defmodule Fleet.TaskQueue do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.EventRouter
    ],
    exports: [WorkItem]

  @moduledoc """
  Public API of the LCARS cross-pod orchestration broker.

  `fleet_spawner` enqueues (source), `fleet_task_queue` distributes/collects (broker),
  `fleet_mcp` serves via the `get_work_item`/`submit_result` tools (vendor boundary),
  `fleet_pilot` (StepRunConsumer) steers post-result.

  Every function has a test-seam variant (explicit `server`, e.g. `enqueue/3`,
  `get_for_pod/2`) for test isolation via an anonymous server (`name: nil`).
  """

  alias Fleet.TaskQueue.Server

  @server Server

  @doc "Enqueues a work item for the identified pod. Generates a `task.id` (UUID v4 = correlation_id)."
  @spec enqueue(String.t(), map()) :: {:ok, Fleet.TaskQueue.WorkItem.t()} | {:error, term()}
  def enqueue(pod_id, task_attrs), do: enqueue(@server, pod_id, task_attrs)

  @spec enqueue(GenServer.server(), String.t(), map()) ::
          {:ok, Fleet.TaskQueue.WorkItem.t()} | {:error, term()}
  def enqueue(server, pod_id, task_attrs) when is_binary(pod_id) and is_map(task_attrs),
    do: GenServer.call(server, {:enqueue, pod_id, task_attrs})

  @doc "Retrieves the pod's active work item (served by fleet_mcp `get_work_item`). Idempotent until submit/clear."
  @spec get_for_pod(String.t()) :: {:ok, Fleet.TaskQueue.WorkItem.t()} | {:error, :no_work_item}
  def get_for_pod(pod_id), do: get_for_pod(@server, pod_id)

  @spec get_for_pod(GenServer.server(), String.t()) ::
          {:ok, Fleet.TaskQueue.WorkItem.t()} | {:error, :no_work_item}
  def get_for_pod(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:get_for_pod, pod_id})

  @doc """
  Submits the result (served by fleet_mcp `submit_result`). Idempotent (2nd call =
  `:double_submit_ignored`). If `result` carries a `work_item_id` ≠ the pod's active work item
  → `:work_item_id_mismatch` (the deliverable's correlation_id does not match), no mutation.

  ## Boundary placement (SOC-STATE-001) — deliberate, not a gap

  `work_item_id` is an OPTIONAL correlation lock HERE: this is the GENERIC broker, and `submit_result`
  completes the pod's active work item (`find_active`) whether or not the correlator is supplied — it is
  only *verified* when present (mismatch → reject). The MANDATORY-`work_item_id` policy is a
  POD-INTERACTION concern, enforced ONE level up at the fleet_mcp boundary (`Fleet.MCP.PodTools.WorkItems`
  always stamps `work_item_id` before calling here) — the only surface where pods actually submit.
  Keeping the broker policy-light while the pod-facing mandatory lives at the interaction edge is the
  intended layering: raising the requirement into the broker would break its generic contract (internal
  callers correlate by the pod's single active item).

  The `work_item.completed` broadcast is LIFECYCLE load-bearing (the StepRunConsumer depends on it to
  finish the step_run). If its broadcast fails, the return is `{:error, {:broadcast_failed, _}}` (the task
  stays `:completed`+persisted, but the caller does NOT receive a false success — no more `:ok` that lies).
  """
  @spec submit_result(String.t(), map()) ::
          {:ok, Fleet.TaskQueue.WorkItem.t()}
          | {:error,
             :no_active_work_item
             | :double_submit_ignored
             | :work_item_id_mismatch
             | {:broadcast_failed, term()}}
  def submit_result(pod_id, result), do: submit_result(@server, pod_id, result)

  @spec submit_result(GenServer.server(), String.t(), map()) ::
          {:ok, Fleet.TaskQueue.WorkItem.t()}
          | {:error,
             :no_active_work_item
             | :double_submit_ignored
             | :work_item_id_mismatch
             | {:broadcast_failed, term()}}
  def submit_result(server, pod_id, result) when is_binary(pod_id) and is_map(result),
    do: GenServer.call(server, {:submit_result, pod_id, result})

  @doc "Lists `:pending` work items. Query Port, no broadcast."
  @spec list_pending() :: [Fleet.TaskQueue.WorkItem.t()]
  def list_pending, do: list_pending(@server)

  @spec list_pending(GenServer.server()) :: [Fleet.TaskQueue.WorkItem.t()]
  def list_pending(server), do: GenServer.call(server, :list_pending)

  @doc """
  Lists the ACTIVE work items (`:pending` | `:assigned` | `:in_progress` — the Server's
  `@active_states` authority, not a re-declaration here). Query Port, no broadcast.

  Consumer: the poller's lock reconciliation (G1) — a work unit under an ACTIVE gatekeeper
  eval is owned (the task's `gate_eval` metadata carries the work unit); an eval that is
  `:cleared` (superseded) or `:completed` no longer is → the reclaim takes over.
  """
  @spec list_active() :: [Fleet.TaskQueue.WorkItem.t()]
  def list_active, do: list_active(@server)

  @spec list_active(GenServer.server()) :: [Fleet.TaskQueue.WorkItem.t()]
  def list_active(server), do: GenServer.call(server, :list_active)

  @doc "Cancels/clears the pod's active work item (teardown). Idempotent."
  @spec clear_for_pod(String.t()) :: :ok
  def clear_for_pod(pod_id), do: clear_for_pod(@server, pod_id)

  @spec clear_for_pod(GenServer.server(), String.t()) :: :ok
  def clear_for_pod(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:clear_for_pod, pod_id})

  @doc """
  Status of the pod's LATEST work item (`{:ok, state | nil}`) — may be TERMINAL
  (`:completed`/`:failed`/`:cleared`), not only active. `{:ok, nil}` means the pod NEVER had a
  task, NOT "no active task" (same `latest_for_pod` read as `pod_active_issue_id/1` — callers
  that need "active only" filter on the state). Query Port.
  """
  @spec pod_status(String.t()) :: {:ok, atom() | nil}
  def pod_status(pod_id), do: pod_status(@server, pod_id)

  @spec pod_status(GenServer.server(), String.t()) :: {:ok, atom() | nil}
  def pod_status(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:pod_status, pod_id})

  @doc """
  issue_id of the pod's LAST task (`{:ok, issue_id | nil}`), WHATEVER its state — no state
  filtering here. Used by the poller (slot-freeze): a project-scoped PIPE eng (pod_id
  `<repo>-engineer`, WITHOUT `-issue-N-`) doesn't say in its id which work unit it holds -> lock
  reconciliation derives it from the task's `issue_id` (e.g. `issue-3`). The reconciliation
  pre-filters pods on `pod_has_active_task?` (F-C050), so only a pod with an ACTIVE task reaches
  this query; the publication window (submit -> :completed -> push) is covered by the
  reconciliation's 2-tick grace + the idempotent completion sequence, NOT by this query. Query Port.
  """
  @spec pod_active_issue_id(String.t()) :: {:ok, String.t() | nil}
  def pod_active_issue_id(pod_id), do: pod_active_issue_id(@server, pod_id)

  @spec pod_active_issue_id(GenServer.server(), String.t()) :: {:ok, String.t() | nil}
  def pod_active_issue_id(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:pod_active_issue_id, pod_id})

  @doc """
  The pod's last poll (`DateTime | nil`) = **in-band ACK**: the agent called `get_for_pod` (even without
  a work item → bootstrap signal "up + armed"). Consumed by the ack-driven wake loop. Query Port.
  """
  @spec last_poll(String.t()) :: DateTime.t() | nil
  def last_poll(pod_id), do: last_poll(@server, pod_id)

  @spec last_poll(GenServer.server(), String.t()) :: DateTime.t() | nil
  def last_poll(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:last_poll, pod_id})
end
