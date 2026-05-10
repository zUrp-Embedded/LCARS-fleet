defmodule Fleet.Pipeline.Toposort do
  @moduledoc """
  Tri topologique DAG des stages d'un pipeline selon le champ `needs`
  (liste des stages prérequis).

  ## API

    * `sort/1` — `%{stage_name => stage_spec}` → `[stage_name]` ordre topo
    * `cycles?/1` — `boolean` détecte présence de cycles

  ## Algorithme

  Kahn's algorithm — itération gloutonne (BFS-like) sur les noeuds
  in-degree 0, tri stable par insertion.
  """

  @type stage_name :: String.t()
  @type stages :: %{optional(stage_name) => map()}

  @doc """
  Trie les stages topologiquement.

  Raises `RuntimeError` si cycle détecté.
  """
  @spec sort(stages()) :: [stage_name()]
  def sort(stages) when is_map(stages) do
    nodes = Map.keys(stages)
    edges = build_edges(stages)
    in_degree = compute_in_degree(nodes, edges)

    {sorted, remaining_in} = kahn(nodes, edges, in_degree, [])

    if Enum.any?(Map.values(remaining_in), &(&1 > 0)) do
      raise "Fleet.Pipeline.Toposort: cycle détecté dans le DAG stages"
    end

    sorted
  end

  @doc """
  Détecte la présence de cycles sans raiser.
  """
  @spec cycles?(stages()) :: boolean()
  def cycles?(stages) when is_map(stages) do
    nodes = Map.keys(stages)
    edges = build_edges(stages)
    in_degree = compute_in_degree(nodes, edges)
    {_sorted, remaining_in} = kahn(nodes, edges, in_degree, [])
    Enum.any?(Map.values(remaining_in), &(&1 > 0))
  end

  defp build_edges(stages) do
    Enum.reduce(stages, %{}, fn {stage_name, spec}, acc ->
      needs = Map.get(spec, "needs") || []

      Enum.reduce(needs, acc, fn dep, acc2 ->
        Map.update(acc2, dep, [stage_name], &[stage_name | &1])
      end)
    end)
  end

  defp compute_in_degree(nodes, edges) do
    base = Map.new(nodes, &{&1, 0})

    Enum.reduce(edges, base, fn {_from, tos}, acc ->
      Enum.reduce(tos, acc, fn to, acc2 ->
        Map.update(acc2, to, 1, &(&1 + 1))
      end)
    end)
  end

  defp kahn(nodes, edges, in_degree, sorted) do
    case Enum.find(nodes, fn n -> Map.get(in_degree, n, 0) == 0 end) do
      nil ->
        {Enum.reverse(sorted), in_degree}

      node ->
        new_in_degree =
          Enum.reduce(Map.get(edges, node, []), in_degree, fn child, acc ->
            Map.update!(acc, child, &(&1 - 1))
          end)
          |> Map.delete(node)

        kahn(nodes -- [node], edges, new_in_degree, [node | sorted])
    end
  end
end
