defmodule Fleet.Pipeline.GraphValidator do
  @moduledoc """
  Linter de GRAPHE **pur** d'une carte (pipeline). Vérifie les invariants
  inter-stages que le JSON Schema ne peut PAS exprimer : le schéma draft-07 valide
  chaque stage ISOLÉMENT (sa forme, ses champs), jamais la relation entre stages.
  Un `needs` mal orthographié passe donc le schéma mais pose une arête fantôme — un
  stage attend un prédécesseur qui n'existe pas, et le pipeline se fige EN SILENCE.

  `validate/1` prend la map `stages` (forme normalisée du Loader,
  `%{nom => %{"needs" => [...], "role" => ..., ...}}`) et retourne `:ok` ou
  `{:error, {kind, detail}}`. Aucune I/O : la décision est de la DATA, testable
  sans fichier. Le Loader appelle ceci après normalisation et raise sur l'erreur
  (même contrat fail-loud que le schéma).

  ## Le graphe

  Un stage B avec `needs: [A]` pose l'arête A → B (A précède B, B est un successeur
  de A). Une carte sans `needs` (ou `needs: []`) est une racine.

  ## Invariants (un `kind` par invariant)

    * `:phantom_edge` — chaque nom dans un `needs` réfère un stage DÉCLARÉ. C'est le
      trou le plus pernicieux : un typo (`needs: [implment]`) est silencieux au schéma.
    * `:no_root` / `:multiple_roots` — exactement 1 stage racine (`needs == []`) ;
      0 = pas de point d'entrée, ≥2 = entrée parallèle (hors-scope du runtime séquentiel).
    * `:unreachable` — tout stage est atteignable depuis la racine (un orphelin ne
      s'exécuterait jamais).
    * `:cycle` — le graphe est un DAG (tri topologique de Kahn). Un cycle fige le
      pipeline. Pour ce runtime séquentiel (racine unique + pas de fan-out), « cycle »
      et « aucun terminal atteignable » sont la MÊME condition : une chaîne qui boucle
      n'a aucun stage sans successeur. L'invariant « ≥1 terminal atteignable » est donc
      garanti par la conjonction racine-unique + acyclicité — une carte sans terminal
      est rejetée ici comme `:cycle` (pas de branche dédiée qui ne pourrait jamais tirer).
    * `:fan_out` — aucun stage n'a ≥2 successeurs. Le runtime est SÉQUENTIEL :
      `Fleet.Pilot.CarteNav.next_stage/2` rejette déjà une branche parallèle à la
      navigation (`:dag_not_supported`) ; on échoue ici au LOAD, plus tôt et cohérent.

  ## Ordre des vérifications

  Chaque check suppose les invariants précédents tenus, ce qui donne le diagnostic le
  plus précis : un blob déconnecté (qui est techniquement aussi un cycle) est diagnostiqué
  `:unreachable` (« ces stages ne sont pas câblés à l'entrée », message actionnable) parce
  que l'atteignabilité est vérifiée AVANT l'acyclicité ; une boucle SUR la chaîne reste
  diagnostiquée `:cycle`.
  """

  @type stages :: %{optional(String.t()) => map()}
  @type kind ::
          :phantom_edge | :no_root | :multiple_roots | :unreachable | :cycle | :fan_out
  @type detail :: map()
  @type error :: {kind(), detail()}

  @spec validate(stages()) :: :ok | {:error, error()}
  def validate(stages) when is_map(stages) do
    # Successeurs construits une fois (dep → [stages qui le `needs`]). Calculé avant les
    # checks : ses seuls consommateurs (atteignabilité / acyclicité / fan-out) tournent
    # APRÈS le check d'arête fantôme, donc sur un graphe déjà prouvé sans arête fantôme.
    successors = successors(stages)

    with :ok <- check_no_phantom_edges(stages),
         {:ok, root} <- check_single_root(stages),
         :ok <- check_all_reachable(stages, successors, root),
         :ok <- check_acyclic(stages, successors),
         :ok <- check_no_fan_out(successors) do
      :ok
    end
  end

  @doc "Message lisible par invariant — composé par le Loader dans son `raise`."
  @spec describe(error()) :: String.t()
  def describe({:phantom_edge, %{stage: stage, needs: dep}}),
    do:
      "le `needs` #{inspect(dep)} du stage #{inspect(stage)} ne réfère aucun stage déclaré — " <>
        "arête fantôme (typo silencieux : le stage attendrait un prédécesseur inexistant et le pipeline se figerait)"

  def describe({:no_root, _}),
    do: "aucun stage racine — il faut exactement un stage d'entrée avec `needs: []`"

  def describe({:multiple_roots, %{roots: roots}}),
    do:
      "plusieurs stages racine #{inspect(roots)} — un seul point d'entrée `needs: []` est autorisé " <>
        "(entrée parallèle hors-scope du runtime séquentiel)"

  def describe({:unreachable, %{stages: orphans}}),
    do:
      "stage(s) orphelin(s) #{inspect(orphans)} inatteignable(s) depuis la racine — ils ne s'exécuteraient jamais"

  def describe({:cycle, %{stages: cyclic}}),
    do:
      "cycle de dépendances impliquant #{inspect(cyclic)} — le graphe doit être un DAG " <>
        "(un cycle fige le pipeline ; c'est aussi le cas d'une chaîne sans terminal atteignable)"

  def describe({:fan_out, %{stage: stage, successors: succs}}),
    do:
      "le stage #{inspect(stage)} a #{length(succs)} successeurs #{inspect(succs)} — le runtime est séquentiel " <>
        "(un seul successeur par stage ; cf. Fleet.Pilot.CarteNav qui rejette le fan-out à la navigation)"

  # ── checks (chacun pur : data → :ok | {:error, {kind, detail}}) ──

  defp check_no_phantom_edges(stages) do
    declared = stages |> Map.keys() |> MapSet.new()

    Enum.reduce_while(stages, :ok, fn {stage, spec}, :ok ->
      case Enum.find(needs(spec), &(not MapSet.member?(declared, &1))) do
        nil -> {:cont, :ok}
        missing -> {:halt, {:error, {:phantom_edge, %{stage: stage, needs: missing}}}}
      end
    end)
  end

  defp check_single_root(stages) do
    case for {name, spec} <- stages, needs(spec) == [], do: name do
      [root] -> {:ok, root}
      [] -> {:error, {:no_root, %{}}}
      roots -> {:error, {:multiple_roots, %{roots: Enum.sort(roots)}}}
    end
  end

  defp check_all_reachable(stages, successors, root) do
    reachable = reach([root], successors, MapSet.new())

    case for name <- Map.keys(stages), not MapSet.member?(reachable, name), do: name do
      [] -> :ok
      orphans -> {:error, {:unreachable, %{stages: Enum.sort(orphans)}}}
    end
  end

  # Acyclicité par tri topologique de Kahn : on retire itérativement les stages dont tous
  # les prédécesseurs (`needs`) sont déjà sortis. Si tous sortent → DAG ; ceux qui restent
  # bloqués (in-degree jamais retombé à 0) forment le/les cycle(s).
  defp check_acyclic(stages, successors) do
    in_degree = Map.new(stages, fn {name, spec} -> {name, length(needs(spec))} end)
    ready = for {name, 0} <- in_degree, do: name
    visited = kahn(ready, in_degree, successors, MapSet.new())

    case for name <- Map.keys(stages), not MapSet.member?(visited, name), do: name do
      [] -> :ok
      cyclic -> {:error, {:cycle, %{stages: Enum.sort(cyclic)}}}
    end
  end

  defp check_no_fan_out(successors) do
    case Enum.find(successors, fn {_dep, succs} -> length(succs) >= 2 end) do
      nil -> :ok
      {stage, succs} -> {:error, {:fan_out, %{stage: stage, successors: Enum.sort(succs)}}}
    end
  end

  # ── primitives de graphe ──

  defp successors(stages) do
    Enum.reduce(stages, %{}, fn {name, spec}, acc ->
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
