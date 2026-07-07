defmodule Fleet.Workflow.GraphValidator do
  @moduledoc """
  **Pure** GRAPH linter for a workflow_map. Checks the inter-step invariants the JSON
  Schema CANNOT express: the draft-07 schema validates each step in ISOLATION (its shape,
  its fields), never the relation between steps. A misspelled `needs` therefore passes the
  schema but lays a phantom edge — a step waits on a predecessor that does not exist, and
  the workflow freezes SILENTLY.

  `validate/1` takes the `steps` map (the Loader's normalized shape,
  `%{name => %{"needs" => [...], "role" => ..., ...}}`) and returns `:ok` or
  `{:error, {kind, detail}}`. No I/O: the decision is pure DATA, testable without a file.
  The Loader calls this after normalization and raises on error (same fail-loud contract
  as the schema).

  ## The graph

  A step B with `needs: [A]` lays the edge A → B (A precedes B, B is a successor of A). A
  workflow_map with no `needs` (or `needs: []`) is a root.

  ## Invariants (one `kind` per invariant)

    * `:phantom_edge` — every name in a `needs` refers to a DECLARED step. This is the
      most insidious hole: a typo (`needs: [implment]`) is silent at the schema.
    * `:no_root` / `:multiple_roots` — exactly 1 root step (`needs == []`);
      0 = no entry point, ≥2 = parallel entry (out of scope for the sequential runtime).
    * `:unreachable` — every step is reachable from the root (an orphan would never run).
    * `:cycle` — the graph is a DAG (Kahn topological sort). A cycle freezes the workflow.
      For this sequential runtime (single root + no fan-out), "cycle" and "no reachable
      terminal" are the SAME condition: a chain that loops has no step without a successor.
      The "≥1 reachable terminal" invariant is therefore guaranteed by the conjunction
      single-root + acyclicity — a workflow_map with no terminal is rejected here as
      `:cycle` (no dedicated branch that could never fire).
    * `:fan_out` — no step has ≥2 successors. The runtime is SEQUENTIAL:
      `Fleet.Pilot.WorkflowMapNav.next_step/2` already rejects a parallel branch at
      navigation (`:dag_not_supported`); we fail here at LOAD, earlier and consistent.

  ## Order of the checks

  Each check assumes the previous invariants hold, which yields the most precise
  diagnostic: a disconnected blob (technically also a cycle) is diagnosed `:unreachable`
  ("these steps are not wired to the entry", an actionable message) because reachability is
  checked BEFORE acyclicity; a loop ON the chain stays diagnosed `:cycle`.
  """

  @type steps :: %{optional(String.t()) => map()}
  @type kind ::
          :phantom_edge | :no_root | :multiple_roots | :unreachable | :cycle | :fan_out
  @type detail :: map()
  @type error :: {kind(), detail()}

  @spec validate(steps()) :: :ok | {:error, error()}
  def validate(steps) when is_map(steps) do
    # Successors built once (dep → [steps that `needs` it]). Computed before the checks:
    # its only consumers (reachability / acyclicity / fan-out) run AFTER the phantom-edge
    # check, so on a graph already proven free of phantom edges.
    successors = successors(steps)

    with :ok <- check_no_phantom_edges(steps),
         {:ok, root} <- check_single_root(steps),
         :ok <- check_all_reachable(steps, successors, root),
         :ok <- check_acyclic(steps, successors),
         :ok <- check_no_fan_out(successors) do
      :ok
    end
  end

  @doc "Human-readable message per invariant — composed by the Loader in its `raise`."
  @spec describe(error()) :: String.t()
  def describe({:phantom_edge, %{step: step, needs: dep}}),
    do:
      "le `needs` #{inspect(dep)} du step #{inspect(step)} ne réfère aucun step déclaré — " <>
        "arête fantôme (typo silencieux : le step attendrait un prédécesseur inexistant et le pipeline se figerait)"

  def describe({:no_root, _}),
    do: "aucun step racine — il faut exactement un step d'entrée avec `needs: []`"

  def describe({:multiple_roots, %{roots: roots}}),
    do:
      "plusieurs steps racine #{inspect(roots)} — un seul point d'entrée `needs: []` est autorisé " <>
        "(entrée parallèle hors-scope du runtime séquentiel)"

  def describe({:unreachable, %{steps: orphans}}),
    do:
      "step(s) orphelin(s) #{inspect(orphans)} inatteignable(s) depuis la racine — ils ne s'exécuteraient jamais"

  def describe({:cycle, %{steps: cyclic}}),
    do:
      "cycle de dépendances impliquant #{inspect(cyclic)} — le graphe doit être un DAG " <>
        "(un cycle fige le pipeline ; c'est aussi le cas d'une chaîne sans terminal atteignable)"

  def describe({:fan_out, %{step: step, successors: succs}}),
    do:
      "le step #{inspect(step)} a #{length(succs)} successeurs #{inspect(succs)} — le runtime est séquentiel " <>
        "(un seul successeur par step ; cf. Fleet.Pilot.WorkflowMapNav qui rejette le fan-out à la navigation)"

  # ── checks (each pure: data → :ok | {:error, {kind, detail}}) ──

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

  # Acyclicity via Kahn topological sort: iteratively remove the steps whose predecessors
  # (`needs`) have all already come out. If all come out → DAG; those that stay blocked
  # (in-degree never dropping back to 0) form the cycle(s).
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

  # ── graph primitives ──

  defp successors(steps) do
    Enum.reduce(steps, %{}, fn {name, spec}, acc ->
      Enum.reduce(needs(spec), acc, fn dep, acc ->
        Map.update(acc, dep, [name], &[name | &1])
      end)
    end)
  end

  defp needs(spec), do: Map.get(spec, "needs", [])

  # Iterative DFS (stack = list) with a seen set: robust even if the region contains a
  # cycle (reachability is deliberately checked before acyclicity).
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
