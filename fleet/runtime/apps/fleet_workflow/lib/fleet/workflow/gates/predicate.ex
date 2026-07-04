defmodule Fleet.Workflow.Gates.Predicate do
  @moduledoc """
  Évaluateur de prédicats des gate `rules` v2.5 (strings) contre les `outputs`
  auto-rapportés par le pod. Module **pur** (pas d'état runtime).

  ## Grammaire (bornée au corpus canon `standard-qa` / `audit-only`)

      rule       := conjunct ( "AND" conjunct )*
      conjunct   := comparison | atom
      comparison := identifier op operand
      op         := ">=" | "<=" | "==" | "!=" | ">" | "<"
      operand    := number | bareword
      atom       := identifier

  - `identifier` est résolu dans `outputs[identifier]` (faits auto-rapportés
    par le pod, ex. `%{"severity_max" => "important", "tasks_count" => 3,
    "spec_doc_exists" => true}`).
  - **atom** (identifiant nu) = vrai ssi `outputs[id] == true` (booléen strict,
    le pod rapporte un fait explicite — pas de truthiness laxiste).
  - **comparison** : `outputs[lhs] op operand`. Nombres pour `>=/>/<=/<` ;
    `==/!=` comparent valeur ↔ operand (bareword → string, ex. `critical`).
  - **conjonction** : `AND` uniquement (le corpus n'utilise ni `OR` ni
    parenthèses ni négation hors `!=`). Une rule = conjonction de tous ses
    termes.

  Limite connue (hors corpus canon) : un operande RHS multi-mots
  (`severity_max != very critical`) est capté comme un seul bareword
  `"very critical"` — borné au corpus actuel (operandes mono-mot/nombre). À
  durcir si un pipeline futur introduit des operandes à espaces.

  ## Fail-closed

  Un fait référencé **absent** des outputs, ou un type incompatible (ex. `>=`
  sur un non-nombre), rend le prédicat **faux** — jamais un pass silencieux sur
  preuve manquante. Le moteur est mécanique : il ne fetch rien, il lit `outputs`.

  ## Hors-scope (non décidé ici)

  L'orchestration adjacente du gate (`human_approval_required`,
  `fallback_invoke_gatekeeper`, `on_blocking_severity`, `on_revision_severity`)
  n'est PAS portée par cet évaluateur — il ne fait QUE `rule_string → bool`.
  Le mapping vers `:pass`/`:fail`/`:retry` (dont le refus d'auto-approuver un
  gate `human_approval_required`) est dans `Fleet.Workflow.Gates`.
  """

  @ops ~w(>= <= == != > <)

  @doc """
  Évalue une rule-string (conjonction de termes `AND`) contre `outputs`.
  Renvoie `true` ssi tous les termes sont satisfaits.

  ## Examples

      iex> alias Fleet.Workflow.Gates.Predicate
      iex> Predicate.eval?("spec_doc_exists AND spec_doc_non_empty",
      ...>   %{"spec_doc_exists" => true, "spec_doc_non_empty" => true})
      true

      iex> Fleet.Workflow.Gates.Predicate.eval?("severity_max != critical",
      ...>   %{"severity_max" => "important"})
      true

      iex> Fleet.Workflow.Gates.Predicate.eval?("tasks_count >= 1", %{"tasks_count" => 0})
      false

      iex> Fleet.Workflow.Gates.Predicate.eval?("all_tests_pass", %{})
      false
  """
  @spec eval?(term(), term()) :: boolean()
  def eval?(rule, outputs) when is_binary(rule) and is_map(outputs) do
    rule
    |> String.split(~r/\s+AND\s+/)
    |> Enum.all?(&eval_term(String.trim(&1), outputs))
  end

  # Clause TOTALE fail-closed. Le hard gate v2.5 applique `eval?` à CHAQUE item de
  # `rules` sans garantir que ce soit une string : asymétrie connue avec le terminal
  # gate, qui lui filtre ses items non-string en amont (`Enum.all?(rules, &is_binary/1)`).
  # Un `rule` non-string (ex. une rule-map d'un gate v1 mal aiguillée vers le chemin
  # hard v2.5, ou un override non schématisé) — ou des `outputs` non-map — rend `false` :
  # le hard gate ÉCHOUE (`Enum.all?` devient false → `{:fail, …}` dans Gates), JAMAIS un
  # FunctionClauseError qui remonterait crasher le StepRunConsumer (singleton). L'éval est
  # rendue TOTALE, symétrique du catch-all fail-closed du terminal.
  def eval?(_rule, _outputs), do: false

  defp eval_term(term, outputs) do
    case parse(term) do
      {:cmp, lhs, op, operand} -> compare(Map.get(outputs, lhs, :__absent__), op, operand)
      {:atom, id} -> Map.get(outputs, id) == true
    end
  end

  # "identifier op operand" → {:cmp, ...} ; sinon identifiant nu → {:atom, id}.
  defp parse(term) do
    case Regex.run(~r/^(\w+)\s*(>=|<=|==|!=|>|<)\s*(.+)$/, term) do
      [_, lhs, op, rhs] when op in @ops -> {:cmp, lhs, op, operand(String.trim(rhs))}
      _ -> {:atom, term}
    end
  end

  defp operand(rhs) do
    case Integer.parse(rhs) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(rhs) do
          {f, ""} -> f
          _ -> rhs
        end
    end
  end

  # Fail-closed : fait absent OU présent-à-nil → prédicat faux (pas de pass sur
  # preuve manquante). Le cas nil est critique pour `!=` : `nil != "critical"`
  # serait `true` en Elixir nu — on le neutralise (nil ≡ absent).
  defp compare(:__absent__, _op, _operand), do: false
  defp compare(nil, _op, _operand), do: false
  defp compare(lhs, "==", operand), do: lhs == operand
  defp compare(lhs, "!=", operand), do: lhs != operand

  defp compare(lhs, op, operand) when is_number(lhs) and is_number(operand) do
    case op do
      ">=" -> lhs >= operand
      "<=" -> lhs <= operand
      ">" -> lhs > operand
      "<" -> lhs < operand
    end
  end

  # Type incompatible (ex. `>=` sur un non-nombre) → fail-closed.
  defp compare(_lhs, _op, _operand), do: false
end
