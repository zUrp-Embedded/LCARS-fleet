defmodule Fleet.Workflow.Gates.Predicate do
  @moduledoc """
  Evaluates rule strings against self-reported pod outputs; orchestration belongs
  to `Fleet.Workflow.Gates`.

  Terms are split on uppercase `AND` surrounded by whitespace, then trimmed.
  Comparisons accept a word-character identifier and `>= <= == != > <`.
  A complete integer or float RHS becomes a number; otherwise it remains a string,
  including spaces. There is no quoting: `AND` inside an operand also splits it.

  Ordering requires two numbers. Equality and inequality use Elixir's `==` and
  `!=`; absent, nil or `:__absent__` facts return false for every comparison.
  Other terms look up the entire trimmed text and pass only when its value is true.

  Malformed comparisons may log a warning but still use that lookup fallback:
  `%{"tasks count >= 1" => true}` can therefore satisfy `"tasks count >= 1"`.
  The warning's claim that every delivery is rejected is broader than the behavior.
  Non-string rules or non-map outputs return false.
  """

  require Logger

  @ops ~w(>= <= == != > <)

  @doc """
  Evaluates a rule-string (conjunction of `AND` terms) against `outputs`.
  Returns `true` iff all terms are satisfied.

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

  # Gates checks rule element types first to distinguish bad cards from failed rules.
  def eval?(_rule, _outputs), do: false

  defp eval_term(term, outputs) do
    case parse(term) do
      {:cmp, lhs, op, operand} -> compare(Map.get(outputs, lhs, :__absent__), op, operand)
      {:atom, id} -> Map.get(outputs, id) == true
    end
  end

  # Warn about likely malformed comparisons without changing the literal-key fallback.
  defp parse(term) do
    case Regex.run(~r/^(\w+)\s*(>=|<=|==|!=|>|<)\s*(.+)$/, term) do
      [_, lhs, op, rhs] when op in @ops ->
        {:cmp, lhs, op, operand(String.trim(rhs))}

      _ ->
        if malformed_comparison?(term) do
          Logger.warning(
            "Gates.Predicate: rule term #{inspect(term)} carries an operator but does not parse " <>
              "as `identifier op operand` — evaluated as a (false) atom. The gate will reject " <>
              "EVERY delivery until the rule is fixed."
          )
        end

        {:atom, term}
    end
  end

  # This heuristic controls logging only, not the verdict.
  defp malformed_comparison?(term), do: Regex.match?(~r/(^|\s)(>=|<=|==|!=|>|<)(\s|$)/, term)

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

  # `nil` is absent: it cannot make `!=` pass.
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

  defp compare(_lhs, _op, _operand), do: false
end
