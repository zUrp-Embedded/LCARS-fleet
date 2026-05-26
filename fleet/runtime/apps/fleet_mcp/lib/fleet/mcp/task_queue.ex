defmodule Fleet.MCP.TaskQueue do
  @moduledoc """
  File de tâches in-memory host-side (substrat R-CORE.comm inc3b.1 — SEAM).

  Source/sink minimal pour la couche tool MCP pod-facing (`Fleet.MCP.PodTools`) :
    - `push/1`    : le fleet dépose une tâche (FIFO).
    - `next/0`    : canal IN — pop la 1ʳᵉ tâche (`:empty` si vide).
    - `submit/1`  : canal OUT — le pod retourne un résultat structuré (append).
    - `results/0` : introspection (tests).

  **GenServer justifié** (état mutable : file + résultats). **Stand-in temporaire** :
  inc3b.3+ remplace cette file in-memory par le vrai câblage Spawner/Pipeline (la
  tâche vient d'une stage, le résultat repart dans le bus). Le contrat
  push/next/submit/results est le seam stable. Mirror Elixir de la fixture
  `test/fixtures/mcp_submit_server.py`. Pas démarrée au boot — instanciée par le
  transport (inc3b.2) ou les tests.
  """

  use GenServer

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Dépose une tâche dans la file (FIFO)."
  @spec push(map()) :: :ok
  def push(task) when is_map(task), do: push(@name, task)

  @doc "Variante test-seam : cible un serveur explicite."
  @spec push(GenServer.server(), map()) :: :ok
  def push(server, task) when is_map(task), do: GenServer.call(server, {:push, task})

  @doc "Canal IN : pop la 1ʳᵉ tâche. `{:ok, task}` | `:empty`."
  @spec next() :: {:ok, map()} | :empty
  def next, do: next(@name)

  @spec next(GenServer.server()) :: {:ok, map()} | :empty
  def next(server), do: GenServer.call(server, :next)

  @doc """
  Canal IN ciblé pod : pop la 1ʳᵉ tâche éligible au pod donné.

  Une tâche est éligible si :
    - `_lcars_pod_id` absent ou nil (untargeted — n'importe quel pod
      peut la prendre, comportement legacy FIFO global) ;
    - `_lcars_pod_id == pod_id` (ciblée pour ce pod précis — pattern
      pipeline multi-pod avec wake_pod).

  Le pod ne voit jamais une tâche d'un autre pod. L'ordre FIFO est
  préservé parmi les éligibles. Untargeted (rouge) ne bloque pas un
  pod ciblé suivant dans la file — le filtre saute les tâches d'un
  autre pod pour trouver la 1ʳᵉ éligible.

  Renvoie `{:ok, task}` (task retirée de la file) ou `:empty`.
  """
  @spec next_for(String.t()) :: {:ok, map()} | :empty
  def next_for(pod_id), do: next_for(@name, pod_id)

  @spec next_for(GenServer.server(), String.t()) :: {:ok, map()} | :empty
  def next_for(server, pod_id) when is_binary(pod_id) do
    GenServer.call(server, {:next_for, pod_id})
  end

  @doc "Canal OUT : enregistre un résultat structuré."
  @spec submit(map()) :: :ok
  def submit(payload) when is_map(payload), do: submit(@name, payload)

  @spec submit(GenServer.server(), map()) :: :ok
  def submit(server, payload) when is_map(payload), do: GenServer.call(server, {:submit, payload})

  @doc "Résultats soumis (ordre de soumission) — introspection/tests."
  @spec results() :: [map()]
  def results, do: results(@name)

  @spec results(GenServer.server()) :: [map()]
  def results(server), do: GenServer.call(server, :results)

  @doc """
  Résultats soumis par un pod donné (corrélation brick 1b). Filtre sur `_pod_id` attaché par
  `submit_result`. Additif — `results/0` reste la liste complète non filtrée.
  """
  @spec results_for(String.t()) :: [map()]
  def results_for(pod_id), do: results_for(@name, pod_id)

  @spec results_for(GenServer.server(), String.t()) :: [map()]
  def results_for(server, pod_id) when is_binary(pod_id) do
    server |> results() |> Enum.filter(&(Map.get(&1, "_pod_id") == pod_id))
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{tasks: [], results: []}}

  @impl GenServer
  def handle_call({:push, task}, _from, %{tasks: t} = state) do
    {:reply, :ok, %{state | tasks: t ++ [task]}}
  end

  def handle_call(:next, _from, %{tasks: []} = state), do: {:reply, :empty, state}

  def handle_call(:next, _from, %{tasks: [task | rest]} = state) do
    {:reply, {:ok, task}, %{state | tasks: rest}}
  end

  def handle_call({:next_for, pod_id}, _from, %{tasks: tasks} = state) do
    case pop_eligible(tasks, pod_id, []) do
      {nil, _} -> {:reply, :empty, state}
      {task, remaining} -> {:reply, {:ok, task}, %{state | tasks: remaining}}
    end
  end

  def handle_call({:submit, payload}, _from, %{results: r} = state) do
    {:reply, :ok, %{state | results: r ++ [payload]}}
  end

  def handle_call(:results, _from, %{results: r} = state), do: {:reply, r, state}

  # Pop la 1ʳᵉ tâche éligible au pod_id (FIFO préservé parmi éligibles).
  # Une tâche est éligible si `_lcars_pod_id` absent/nil OU == pod_id.
  defp pop_eligible([], _pod_id, kept), do: {nil, Enum.reverse(kept)}

  defp pop_eligible([task | rest], pod_id, kept) do
    case Map.get(task, "_lcars_pod_id") do
      nil -> {task, Enum.reverse(kept) ++ rest}
      ^pod_id -> {task, Enum.reverse(kept) ++ rest}
      _other -> pop_eligible(rest, pod_id, [task | kept])
    end
  end
end
