defmodule Fleet.Workflow.GraphValidator do
  @moduledoc """
  Linter de GRAPHE **pur** d'une workflow_map (pipeline). Vérifie les invariants
  inter-steps que le JSON Schema ne peut PAS exprimer : le schéma draft-07 valide
  chaque step ISOLÉMENT (sa forme, ses champs), jamais la relation entre steps.
  Un `needs` mal orthographié passe donc le schéma mais pose une arête fantôme — un
  step attend un prédécesseur qui n'existe pas, et le pipeline se fige EN SILENCE.

  `validate/1` prend la map `steps` (forme normalisée du Loader,
  `%{nom => %{"needs" => [...], "role" => ..., ...}}`) et retourne `:ok` ou
  `{:error, {kind, detail}}`. Aucune I/O : la décision est de la DATA, testable
  sans fichier. Le Loader appelle ceci après normalisation et raise sur l'erreur
  (même contrat fail-loud que le schéma).

  ## Le graphe

  Un step B avec `needs: [A]` pose l'arête A → B (A précède B, B est un successeur
  de A). Une workflow_map sans `needs` (ou `needs: []`) est une racine.

  ## Invariants (un `kind` par invariant)

    * `:phantom_edge` — chaque nom dans un `needs` réfère un step DÉCLARÉ. C'est le
      trou le plus pernicieux : un typo (`needs: [implment]`) est silencieux au schéma.
    * `:no_root` / `:multiple_roots` — exactement 1 step racine (`needs == []`) ;
      0 = pas de point d'entrée, ≥2 = entrée parallèle (hors-scope du runtime séquentiel).
    * `:unreachable` — tout step est atteignable depuis la racine (un orphelin ne
      s'exécuterait jamais).
    * `:cycle` — le graphe est un DAG (tri topologique de Kahn). Un cycle fige le
      pipeline. Pour ce runtime séquentiel (racine unique + pas de fan-out), « cycle »
      et « aucun terminal atteignable » sont la MÊME condition : une chaîne qui boucle
      n'a aucun step sans successeur. L'invariant « ≥1 terminal atteignable » est donc
      garanti par la conjonction racine-unique + acyclicité — une workflow_map sans terminal
      est rejetée ici comme `:cycle` (pas de branche dédiée qui ne pourrait jamais tirer).
    * `:fan_out` — aucun step n'a ≥2 successeurs. Le runtime est SÉQUENTIEL :
      `Fleet.Pilot.WorkflowMapNav.next_step/2` rejette déjà une branche parallèle à la
      navigation (`:dag_not_supported`) ; on échoue ici au LOAD, plus tôt et cohérent.

  ## Ordre des vérifications

  Chaque check suppose les invariants précédents tenus, ce qui donne le diagnostic le
  plus précis : un blob déconnecté (qui est techniquement aussi un cycle) est diagnostiqué
  `:unreachable` (« ces steps ne sont pas câblés à l'entrée », message actionnable) parce
  que l'atteignabilité est vérifiée AVANT l'acyclicité ; une boucle SUR la chaîne reste
  diagnostiquée `:cycle`.
  """

  @type steps :: %{optional(String.t()) => map()}
  @type kind ::
          :phantom_edge | :no_root | :multiple_roots | :unreachable | :cycle | :fan_out
  @type detail :: map()
  @type error :: {kind(), detail()}

  @spec validate(steps()) :: :ok | {:error, error()}
  def validate(steps) when is_map(steps) do
    # Successeurs construits une fois (dep → [steps qui le `needs`]). Calculé avant les
    # checks : ses seuls consommateurs (atteignabilité / acyclicité / fan-out) tournent
    # APRÈS le check d'arête fantôme, donc sur un graphe déjà prouvé sans arête fantôme.
    successors = successors(steps)

    with :ok <- check_no_phantom_edges(steps),
         {:ok, root} <- check_single_root(steps),
         :ok <- check_all_reachable(steps, successors, root),
         :ok <- check_acyclic(steps, successors),
         :ok <- check_no_fan_out(successors) do
      :ok
    end
  end

  @doc "Message lisible par invariant — composé par le Loader dans son `raise`."
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

  # ── checks (chacun pur : data → :ok | {:error, {kind, detail}}) ──

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

  # Acyclicité par tri topologique de Kahn : on retire itérativement les steps dont tous
  # les prédécesseurs (`needs`) sont déjà sortis. Si tous sortent → DAG ; ceux qui restent
  # bloqués (in-degree jamais retombé à 0) forment le/les cycle(s).
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

  # ── primitives de graphe ──

  defp successors(steps) do
    Enum.reduce(steps, %{}, fn {name, spec}, acc ->
      Enum.reduce(needs(spec), acc, fn dep, acc ->
        Map.update(acc, dep, [name], &[name | &1])
      end)
    end)
  end

  defp needs(spec), do: Map.get(spec, "needs", [])

  # DFS itératif (pile = liste) avec ensemble vu : robuste même si la région contient un
  # cycle (l'atteignabilité est volontairement vérifiée avant l'acyclicité).
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
