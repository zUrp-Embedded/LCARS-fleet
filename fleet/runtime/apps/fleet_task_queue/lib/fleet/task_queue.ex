defmodule Fleet.TaskQueue do
  @moduledoc """
  API publique du broker d'orchestration cross-pod LCARS.

  `fleet_spawner` enqueue (source), `fleet_task_queue` distribue/collecte (broker),
  `fleet_mcp` sert via tools `get_work_item`/`submit_result` (frontière vendor),
  `fleet_coord` oriente post-résultat.

  Chaque fonction a une variante test-seam (`server` explicite, ex. `enqueue/3`,
  `get_for_pod/2`) pour l'isolation des tests via serveur anonyme (`name: nil`).
  """

  alias Fleet.TaskQueue.Server

  @server Server

  @doc "Enqueue un work item pour le pod identifié. Génère un `task.id` (UUID v4 = correlation_id)."
  @spec enqueue(String.t(), map()) :: {:ok, Fleet.TaskQueue.WorkItem.t()} | {:error, term()}
  def enqueue(pod_id, task_attrs), do: enqueue(@server, pod_id, task_attrs)

  @spec enqueue(GenServer.server(), String.t(), map()) ::
          {:ok, Fleet.TaskQueue.WorkItem.t()} | {:error, term()}
  def enqueue(server, pod_id, task_attrs) when is_binary(pod_id) and is_map(task_attrs),
    do: GenServer.call(server, {:enqueue, pod_id, task_attrs})

  @doc "Récupère le work item actif du pod (servi par fleet_mcp `get_work_item`). Idempotent jusqu'à submit/clear."
  @spec get_for_pod(String.t()) :: {:ok, Fleet.TaskQueue.WorkItem.t()} | {:error, :no_work_item}
  def get_for_pod(pod_id), do: get_for_pod(@server, pod_id)

  @spec get_for_pod(GenServer.server(), String.t()) ::
          {:ok, Fleet.TaskQueue.WorkItem.t()} | {:error, :no_work_item}
  def get_for_pod(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:get_for_pod, pod_id})

  @doc """
  Soumet le résultat (servi par fleet_mcp `submit_result`). Idempotent (2e appel =
  `:double_submit_ignored`). Si `result` porte un `work_item_id` ≠ work item actif du pod
  → `:work_item_id_mismatch` (le correlation_id du livrable ne matche pas), aucune mutation.

  Le broadcast `work_item.completed` est LIFECYCLE load-bearing (le StepRunConsumer en dépend pour
  finir le step_run). Si sa diffusion échoue, le retour est `{:error, {:broadcast_failed, _}}` (la tâche
  reste `:completed`+persistée, mais le caller NE reçoit PAS un faux succès — plus de `:ok` qui ment).
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

  @doc "Liste les work items `:pending`. Query Port, pas de broadcast."
  @spec list_pending() :: [Fleet.TaskQueue.WorkItem.t()]
  def list_pending, do: list_pending(@server)

  @spec list_pending(GenServer.server()) :: [Fleet.TaskQueue.WorkItem.t()]
  def list_pending(server), do: GenServer.call(server, :list_pending)

  @doc "Annule/clear le work item actif du pod (teardown). Idempotent."
  @spec clear_for_pod(String.t()) :: :ok
  def clear_for_pod(pod_id), do: clear_for_pod(@server, pod_id)

  @spec clear_for_pod(GenServer.server(), String.t()) :: :ok
  def clear_for_pod(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:clear_for_pod, pod_id})

  @doc "Statut du work item actif du pod (`{:ok, state | nil}`). Query Port."
  @spec pod_status(String.t()) :: {:ok, atom() | nil}
  def pod_status(pod_id), do: pod_status(@server, pod_id)

  @spec pod_status(GenServer.server(), String.t()) :: {:ok, atom() | nil}
  def pod_status(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:pod_status, pod_id})

  @doc """
  Issue de la DERNIERE tache du pod (`{:ok, issue_id | nil}`). Sert au poller (slot-freeze) : un eng
  PIPE project-scoped (pod_id `<repo>-engineer`, SANS `-issue-N-`) ne dit pas dans son id quelle brique
  il tient -> la reconciliation de verrou la derive de sa tache active (le `issue_id`, ex. `issue-3`).
  Rend la DERNIERE tache (pas seulement :pending/:assigned) pour couvrir la fenetre de publication
  (submit -> :completed -> push) ou le pod tient ENCORE le verrou de la brique livree. Query Port.
  """
  @spec pod_active_issue_id(String.t()) :: {:ok, String.t() | nil}
  def pod_active_issue_id(pod_id), do: pod_active_issue_id(@server, pod_id)

  @spec pod_active_issue_id(GenServer.server(), String.t()) :: {:ok, String.t() | nil}
  def pod_active_issue_id(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:pod_active_issue_id, pod_id})

  @doc """
  Dernier poll du pod (`DateTime | nil`) = **ACK in-band** : l'agent a appelé `get_for_pod` (même sans
  work item → signal bootstrap « up + armé »). Consommé par la boucle wake ack-driven. Query Port.
  """
  @spec last_poll(String.t()) :: DateTime.t() | nil
  def last_poll(pod_id), do: last_poll(@server, pod_id)

  @spec last_poll(GenServer.server(), String.t()) :: DateTime.t() | nil
  def last_poll(server, pod_id) when is_binary(pod_id),
    do: GenServer.call(server, {:last_poll, pod_id})
end
