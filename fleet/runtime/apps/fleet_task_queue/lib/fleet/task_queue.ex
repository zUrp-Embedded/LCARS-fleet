defmodule Fleet.TaskQueue do
  @moduledoc """
  API publique du broker d'orchestration cross-pod LCARS.

  Cf. DN `orchestration/task-queue` §C. `fleet_spawner` enqueue (source),
  `fleet_task_queue` distribue/collecte (broker), `fleet_mcp` sert via tools
  `get_task`/`submit_result` (frontière vendor), `fleet_coord` oriente post-résultat.

  Chaque fonction a une variante test-seam (`server` explicite, ex. `enqueue/3`,
  `get_for_pod/2`) pour l'isolation des tests via serveur anonyme (`name: nil`).
  """

  alias Fleet.TaskQueue.Server

  @server Server

  @doc "Enqueue un mandat pour le pod identifié. Génère un `task.id` (UUID v4 = correlation_id)."
  @spec enqueue(String.t(), map()) :: {:ok, Fleet.TaskQueue.Task.t()} | {:error, term()}
  def enqueue(pod_id, task_attrs), do: enqueue(@server, pod_id, task_attrs)

  @spec enqueue(GenServer.server(), String.t(), map()) ::
          {:ok, Fleet.TaskQueue.Task.t()} | {:error, term()}
  def enqueue(server, pod_id, task_attrs) when is_binary(pod_id) and is_map(task_attrs),
    do: GenServer.call(server, {:enqueue, pod_id, task_attrs})

  @doc "Récupère le mandat actif du pod (servi par fleet_mcp `get_task`). Idempotent jusqu'à submit/clear."
  @spec get_for_pod(String.t()) :: {:ok, Fleet.TaskQueue.Task.t()} | {:error, :no_task}
  def get_for_pod(pod_id), do: get_for_pod(@server, pod_id)

  @spec get_for_pod(GenServer.server(), String.t()) ::
          {:ok, Fleet.TaskQueue.Task.t()} | {:error, :no_task}
  def get_for_pod(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:get_for_pod, pod_id})

  @doc """
  Soumet le résultat (servi par fleet_mcp `submit_result`). Idempotent (2e appel =
  `:double_submit_ignored`). Si `result` porte un `task_id` ≠ mandat actif du pod
  → `:task_id_mismatch` (validation correlation §A.70), aucune mutation.
  """
  @spec submit_result(String.t(), map()) ::
          {:ok, Fleet.TaskQueue.Task.t()}
          | {:error, :no_active_task | :double_submit_ignored | :task_id_mismatch}
  def submit_result(pod_id, result), do: submit_result(@server, pod_id, result)

  @spec submit_result(GenServer.server(), String.t(), map()) ::
          {:ok, Fleet.TaskQueue.Task.t()}
          | {:error, :no_active_task | :double_submit_ignored | :task_id_mismatch}
  def submit_result(server, pod_id, result) when is_binary(pod_id) and is_map(result),
    do: GenServer.call(server, {:submit_result, pod_id, result})

  @doc "Liste les mandats `:pending`. Query Port, pas de broadcast."
  @spec list_pending() :: [Fleet.TaskQueue.Task.t()]
  def list_pending, do: list_pending(@server)

  @spec list_pending(GenServer.server()) :: [Fleet.TaskQueue.Task.t()]
  def list_pending(server), do: GenServer.call(server, :list_pending)

  @doc "Annule/clear le mandat actif du pod (teardown). Idempotent."
  @spec clear_for_pod(String.t()) :: :ok
  def clear_for_pod(pod_id), do: clear_for_pod(@server, pod_id)

  @spec clear_for_pod(GenServer.server(), String.t()) :: :ok
  def clear_for_pod(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:clear_for_pod, pod_id})

  @doc "Statut du mandat actif du pod (`{:ok, state | nil}`). Query Port."
  @spec pod_status(String.t()) :: {:ok, atom() | nil}
  def pod_status(pod_id), do: pod_status(@server, pod_id)

  @spec pod_status(GenServer.server(), String.t()) :: {:ok, atom() | nil}
  def pod_status(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:pod_status, pod_id})
end
