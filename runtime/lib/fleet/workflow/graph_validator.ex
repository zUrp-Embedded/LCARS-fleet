defmodule Fleet.Workflow.GraphValidator do
  @moduledoc """
  Workflow graph linter after schema validation. Step values must be maps with
  list-valued `needs` when present; an omitted `needs` defaults to `[]`.
  It rejects phantom edges,
  non-single roots, unreachable steps, cycles, and fan-out for the sequential runtime.
  """

  @type steps :: %{optional(String.t()) => map()}
  @type kind ::
          :phantom_edge | :no_root | :multiple_roots | :unreachable | :cycle | :fan_out
  @type detail :: map()
  @type error :: {kind(), detail()}

  @doc """
  Validates a card's step graph: no phantom edge, exactly one root, all reachable, acyclic, no
  fan-out.

  Returns `{:error, {kind, detail}}` in that check order; `describe/1` renders it.
  The engine advances one successor at a time. Repeated dependencies count as
  repeated edges and can trigger fan-out rejection.
  """
  @spec validate(steps()) :: :ok | {:error, error()}
  def validate(steps) when is_map(steps) do
    # Shared adjacency for reachability, acyclicity, and fan-out checks.
    successors = successors(steps)

    with :ok <- check_no_phantom_edges(steps),
         {:ok, root} <- check_single_root(steps),
         :ok <- check_all_reachable(steps, successors, root),
         :ok <- check_acyclic(steps, successors) do
      check_no_fan_out(successors)
    end
  end

  @doc "Human-readable invariant diagnostics for Loader errors."
  @spec describe(error()) :: String.t()
  def describe({:phantom_edge, %{step: step, needs: dep}}),
    do:
      "the `needs` #{inspect(dep)} of step #{inspect(step)} refers to no declared step — " <>
        "phantom edge (silent typo: the step would wait on a nonexistent predecessor and the pipeline would freeze)"

  def describe({:no_root, _}),
    do: "no root step — exactly one entry step with `needs: []` is required"

  def describe({:multiple_roots, %{roots: roots}}),
    do:
      "multiple root steps #{inspect(roots)} — a single `needs: []` entry point is allowed " <>
        "(parallel entry is out of scope for the sequential runtime)"

  def describe({:unreachable, %{steps: orphans}}),
    do: "orphan step(s) #{inspect(orphans)} unreachable from the root — they would never run"

  def describe({:cycle, %{steps: cyclic}}),
    do:
      "dependency cycle involving #{inspect(cyclic)} — the graph must be a DAG " <>
        "(a cycle freezes the pipeline; a chain with no reachable terminal is the same condition)"

  def describe({:fan_out, %{step: step, successors: succs}}),
    do:
      "step #{inspect(step)} has #{length(succs)} successors #{inspect(succs)} — the runtime is sequential " <>
        "(a single successor per step; cf. Fleet.Pilot.WorkflowMapNav, which rejects fan-out at navigation)"

  defp check_no_phantom_edges(steps) do
    declared = steps |> Map.keys() |> MapSet.new()

    Enum.reduce_while(steps, :ok, fn {step, spec}, :ok ->
      case Enum.find(needs(spec), &(not MapSet.member?(declared, &1))) do
        nil -> {:cont, :ok}
        missing -> {:halt, {:error, {:phantom_edge, %{step: step, needs: missing}}}}
      end
    end)
  end

  defp check_single_root(steps) do
    case for {name, spec} <- steps, needs(spec) == [], do: name do
      [root] -> {:ok, root}
      [] -> {:error, {:no_root, %{}}}
      roots -> {:error, {:multiple_roots, %{roots: Enum.sort(roots)}}}
    end
  end

  defp check_all_reachable(steps, successors, root) do
    reachable = reach([root], successors, MapSet.new())

    case for name <- Map.keys(steps), not MapSet.member?(reachable, name), do: name do
      [] -> :ok
      orphans -> {:error, {:unreachable, %{steps: Enum.sort(orphans)}}}
    end
  end

  # Kahn's unvisited set includes cycles and any descendants blocked by them.
  defp check_acyclic(steps, successors) do
    in_degree = Map.new(steps, fn {name, spec} -> {name, length(needs(spec))} end)
    ready = for {name, 0} <- in_degree, do: name
    visited = kahn(ready, in_degree, successors, MapSet.new())

    case for name <- Map.keys(steps), not MapSet.member?(visited, name), do: name do
      [] -> :ok
      cyclic -> {:error, {:cycle, %{steps: Enum.sort(cyclic)}}}
    end
  end

  defp check_no_fan_out(successors) do
    case Enum.find(successors, fn {_dep, succs} -> length(succs) >= 2 end) do
      nil -> :ok
      {step, succs} -> {:error, {:fan_out, %{step: step, successors: Enum.sort(succs)}}}
    end
  end

  defp successors(steps) do
    Enum.reduce(steps, %{}, fn {name, spec}, acc ->
      Enum.reduce(needs(spec), acc, fn dep, acc ->
        Map.update(acc, dep, [name], &[name | &1])
      end)
    end)
  end

  defp needs(spec), do: Map.get(spec, "needs", [])

  # Iterative DFS remains safe before cycle validation.
  defp reach([], _successors, seen), do: seen

  defp reach([node | rest], successors, seen) do
    if MapSet.member?(seen, node) do
      reach(rest, successors, seen)
    else
      reach(Map.get(successors, node, []) ++ rest, successors, MapSet.put(seen, node))
    end
  end

  defp kahn([], _in_degree, _successors, visited), do: visited

  defp kahn([node | rest], in_degree, successors, visited) do
    {in_degree, newly_ready} =
      successors
      |> Map.get(node, [])
      |> Enum.reduce({in_degree, []}, fn succ, {deg, ready} ->
        deg = Map.update!(deg, succ, &(&1 - 1))
        if Map.fetch!(deg, succ) == 0, do: {deg, [succ | ready]}, else: {deg, ready}
      end)

    kahn(newly_ready ++ rest, in_degree, successors, MapSet.put(visited, node))
  end
end
