defmodule Fleet.TaskQueue do
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

  `Fleet.Spawner` enqueues (source), this domain distributes/collects (broker),
  `Fleet.MCP` serves via the `get_work_item`/`submit_result` tools,
  `Fleet.Pilot` (StepRunConsumer) steers post-result.

  Every function has a test-seam variant (explicit `server`, e.g. `enqueue/3`,
  `get_for_pod/2`) for test isolation via an anonymous server (`name: nil`).
  """

  alias Fleet.TaskQueue.WorkItem
  alias Fleet.TaskQueue.Server

  @server Server

  @doc "Enqueues a work item for the identified pod. Generates a `task.id` (UUID v4 = correlation_id)."
  @spec enqueue(String.t(), map()) :: {:ok, WorkItem.t()} | {:error, term()}
  def enqueue(pod_id, task_attrs), do: enqueue(@server, pod_id, task_attrs)

  @spec enqueue(GenServer.server(), String.t(), map()) ::
          {:ok, WorkItem.t()} | {:error, term()}
  def enqueue(server, pod_id, task_attrs) when is_binary(pod_id) and is_map(task_attrs),
    do: GenServer.call(server, {:enqueue, pod_id, task_attrs})

  @doc "Retrieves the pod's active work item, idempotently until completion or clear."
  @spec get_for_pod(String.t()) :: {:ok, WorkItem.t()} | {:error, :no_work_item}
  def get_for_pod(pod_id), do: get_for_pod(@server, pod_id)

  @spec get_for_pod(GenServer.server(), String.t()) ::
          {:ok, WorkItem.t()} | {:error, :no_work_item}
  def get_for_pod(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:get_for_pod, pod_id})

  @doc """
  Submits the pod's active work-item result. A supplied `work_item_id` must match;
  the pod-facing MCP boundary makes that correlator mandatory.

  Completion is broadcast before commit. A broadcast failure returns
  `{:error, {:broadcast_failed, reason}}` and leaves the item active so a retry
  can replay delivery.
  """
  @spec submit_result(String.t(), map()) ::
          {:ok, WorkItem.t()}
          | {:error,
             :no_active_work_item
             | :double_submit_ignored
             | :work_item_not_pulled
             | :work_item_id_mismatch
             | {:broadcast_failed, term()}}
  def submit_result(pod_id, result), do: submit_result(@server, pod_id, result)

  @spec submit_result(GenServer.server(), String.t(), map()) ::
          {:ok, WorkItem.t()}
          | {:error,
             :no_active_work_item
             | :double_submit_ignored
             | :work_item_not_pulled
             | :work_item_id_mismatch
             | {:broadcast_failed, term()}}
  def submit_result(server, pod_id, result) when is_binary(pod_id) and is_map(result),
    do: GenServer.call(server, {:submit_result, pod_id, result})

  @doc "Lists pending work items."
  @spec list_pending() :: [WorkItem.t()]
  def list_pending, do: list_pending(@server)

  @spec list_pending(GenServer.server()) :: [WorkItem.t()]
  def list_pending(server), do: GenServer.call(server, :list_pending)

  @doc """
  Lists the ACTIVE work items (`:pending` | `:assigned` — the Server's
  `@active_states` authority, not a re-declaration here). Query Port, no broadcast.

  Consumer: the poller's lock reconciliation (G1) — a work unit under an ACTIVE gatekeeper
  eval is owned (the task's `gate_eval` metadata carries the work unit); an eval that is
  `:cleared` (superseded) or `:completed` no longer is → the reclaim takes over.
  """
  @spec list_active() :: [WorkItem.t()]
  def list_active, do: list_active(@server)

  @spec list_active(GenServer.server()) :: [WorkItem.t()]
  def list_active(server), do: GenServer.call(server, :list_active)

  @doc "Clears all active work items for a pod. Idempotent."
  @spec clear_for_pod(String.t()) :: :ok
  def clear_for_pod(pod_id), do: clear_for_pod(@server, pod_id)

  @spec clear_for_pod(GenServer.server(), String.t()) :: :ok
  def clear_for_pod(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:clear_for_pod, pod_id})

  @doc """
  Returns the state of the pod's latest work item, including terminal states.

  `{:ok, nil}` means the pod has no recorded work item.
  """
  @spec pod_status(String.t()) :: {:ok, atom() | nil}
  def pod_status(pod_id), do: pod_status(@server, pod_id)

  @spec pod_status(GenServer.server(), String.t()) :: {:ok, atom() | nil}
  def pod_status(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:pod_status, pod_id})

  @doc """
  Returns the issue ID of the pod's latest work item without filtering by state.
  """
  @spec pod_active_issue_id(String.t()) :: {:ok, String.t() | nil}
  def pod_active_issue_id(pod_id), do: pod_active_issue_id(@server, pod_id)

  @spec pod_active_issue_id(GenServer.server(), String.t()) :: {:ok, String.t() | nil}
  def pod_active_issue_id(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:pod_active_issue_id, pod_id})

  @doc """
  Returns when the pod last called `get_for_pod`, including empty polls.
  """
  @spec last_poll(String.t()) :: DateTime.t() | nil
  def last_poll(pod_id), do: last_poll(@server, pod_id)

  @spec last_poll(GenServer.server(), String.t()) :: DateTime.t() | nil
  def last_poll(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:last_poll, pod_id})

  @doc """
  The pod's MCP client has spoken on its socket at least once — i.e. its REPL is UP.

  Weaker than `last_poll/1` and that is what makes it useful: a client connects and lists tools at
  TUI init, BEFORE the agent takes any turn. It is the only in-band evidence available during a
  cold start, and the kick loop needs exactly that — keys typed into a REPL that is not up yet are
  buffered by tmux and replayed by the TUI as that many spurious submissions.
  """
  @spec mark_connected(String.t()) :: :ok
  def mark_connected(pod_id), do: mark_connected(@server, pod_id)

  @spec mark_connected(GenServer.server(), String.t()) :: :ok
  def mark_connected(server, pod_id) when is_binary(pod_id),
    do: GenServer.cast(server, {:mark_connected, pod_id})

  @doc "Has this pod's MCP client ever spoken (cf. `mark_connected/1`)? Query Port."
  @spec connected?(String.t()) :: boolean()
  def connected?(pod_id), do: connected?(@server, pod_id)

  @spec connected?(GenServer.server(), String.t()) :: boolean()
  def connected?(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:connected?, pod_id})
end
