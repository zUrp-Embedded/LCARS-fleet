defmodule Fleet.Pipeline.PodRegistry do
  @moduledoc """
  Registre des pods pipe-scoped d'un pipeline.

  Permet à `Fleet.Pipeline.StageRunner` de réutiliser le même pod (typiquement
  engineer long-lived avec `lifetime_scope: pipe`) à travers les stages, au
  lieu de spawn un nouveau pod à chaque cycle (audit → renvoi-au-dev →
  retry-implement, doctrine pipeline-implementation.md Phase III).

  ## State

      %{
        # primary : lookup rapide {pipeline_id, role} → pod_id
        bindings: %{{pipeline_id, role} => pod_id},
        # reverse : pour unregister(pod_id), retrouver le binding
        reverse: %{pod_id => {pipeline_id, role}}
      }

  ## Pourquoi GenServer + Map (pas Registry built-in)

  `Registry` Elixir associe une key à un pid (+ metadata). Ici on stocke
  une string `pod_id` sans process actif côté registry — pas de match.
  GenServer + Map = trivial, blast radius nul, ordre d'insertion ignoré
  (pas de FIFO à préserver, juste lookup keyed).

  ## Iron Law

  Un seul mécanisme paramétré : tous les pods pipe-scoped passent par
  ce registry. Un pod one-shot n'est jamais enregistré (cycle vie =
  cycle stage, pas de réutilisation). C'est `StageRunner` qui décide
  selon `cap_profile.spec.invocation.lifetime_scope`.
  """

  use GenServer

  @name __MODULE__

  @type pipeline_id :: term()
  @type role :: String.t()
  @type pod_id :: String.t()

  # ============================================================
  # Public API
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Associe `pod_id` au couple `{pipeline_id, role}`. Idempotent : un
  re-register sur la même clé écrase l'ancien pod_id (rare — symptôme
  d'un spawn fantôme à investiguer côté StageRunner).
  """
  @spec register(pipeline_id(), role(), pod_id()) :: :ok
  def register(pipeline_id, role, pod_id) when is_binary(role) and is_binary(pod_id) do
    GenServer.call(@name, {:register, pipeline_id, role, pod_id})
  end

  @doc """
  Cherche le pod_id associé à `{pipeline_id, role}`. Renvoie
  `{:ok, pod_id}` si trouvé, `:not_found` sinon.
  """
  @spec lookup(pipeline_id(), role()) :: {:ok, pod_id()} | :not_found
  def lookup(pipeline_id, role) when is_binary(role) do
    GenServer.call(@name, {:lookup, pipeline_id, role})
  end

  @doc """
  Renvoie tous les pods d'un pipeline sous forme `%{role => pod_id}`.
  Utilisé par cleanup_pipeline + introspection.
  """
  @spec pods_for(pipeline_id()) :: %{role() => pod_id()}
  def pods_for(pipeline_id) do
    GenServer.call(@name, {:pods_for, pipeline_id})
  end

  @doc """
  Désenregistre un pod par son `pod_id` (cleanup ciblé). Renvoie
  `:ok` si trouvé/retiré, `:not_found` sinon.
  """
  @spec unregister(pod_id()) :: :ok | :not_found
  def unregister(pod_id) when is_binary(pod_id) do
    GenServer.call(@name, {:unregister, pod_id})
  end

  @doc """
  Cleanup tous les pods d'un pipeline (à `pipeline.completed` /
  `pipeline.failed`). Renvoie la liste des `pod_id` retirés — le
  caller (Pipeline.Executor) les kill via `Fleet.Spawner.kill_pod/1`.
  """
  @spec cleanup_pipeline(pipeline_id()) :: {:ok, [pod_id()]}
  def cleanup_pipeline(pipeline_id) do
    GenServer.call(@name, {:cleanup_pipeline, pipeline_id})
  end

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(_opts), do: {:ok, %{bindings: %{}, reverse: %{}}}

  @impl GenServer
  def handle_call({:register, pipeline_id, role, pod_id}, _from, state) do
    # Si un autre pod était déjà sur cette clé, on l'évacue du reverse map
    # pour préserver la cohérence reverse↔bindings.
    reverse =
      case Map.get(state.bindings, {pipeline_id, role}) do
        nil -> state.reverse
        old_pod -> Map.delete(state.reverse, old_pod)
      end

    bindings = Map.put(state.bindings, {pipeline_id, role}, pod_id)
    reverse = Map.put(reverse, pod_id, {pipeline_id, role})
    {:reply, :ok, %{state | bindings: bindings, reverse: reverse}}
  end

  def handle_call({:lookup, pipeline_id, role}, _from, state) do
    case Map.get(state.bindings, {pipeline_id, role}) do
      nil -> {:reply, :not_found, state}
      pod_id -> {:reply, {:ok, pod_id}, state}
    end
  end

  def handle_call({:pods_for, pipeline_id}, _from, state) do
    pods =
      for {{^pipeline_id, role}, pod_id} <- state.bindings, into: %{}, do: {role, pod_id}

    {:reply, pods, state}
  end

  def handle_call({:unregister, pod_id}, _from, state) do
    case Map.pop(state.reverse, pod_id) do
      {nil, _} ->
        {:reply, :not_found, state}

      {key, reverse} ->
        bindings = Map.delete(state.bindings, key)
        {:reply, :ok, %{state | bindings: bindings, reverse: reverse}}
    end
  end

  def handle_call({:cleanup_pipeline, pipeline_id}, _from, state) do
    {to_remove, kept} =
      Enum.split_with(state.bindings, fn
        {{^pipeline_id, _role}, _pod_id} -> true
        _ -> false
      end)

    removed_pods = Enum.map(to_remove, fn {_key, pod_id} -> pod_id end)
    reverse = Enum.reduce(removed_pods, state.reverse, &Map.delete(&2, &1))
    {:reply, {:ok, removed_pods}, %{state | bindings: Map.new(kept), reverse: reverse}}
  end
end
