defmodule Fleet.Workflow.Gates.Predicate do
  @moduledoc """
  Predicate evaluator for gate `rules` v2.5 (strings) against the `outputs`
  self-reported by the pod. **Pure** module (no runtime state).

  ## Grammar (bounded to the canon corpus `standard-qa` / `audit-only`)

      rule       := conjunct ( "AND" conjunct )*
      conjunct   := comparison | atom
      comparison := identifier op operand
      op         := ">=" | "<=" | "==" | "!=" | ">" | "<"
      operand    := number | bareword
      atom       := identifier

  - `identifier` is resolved in `outputs[identifier]` (facts self-reported
    by the pod, e.g. `%{"severity_max" => "important", "tasks_count" => 3,
    "spec_doc_exists" => true}`).
  - **atom** (bare identifier) = true iff `outputs[id] == true` (strict
    boolean, the pod reports an explicit fact — no lax truthiness).
  - **comparison**: `outputs[lhs] op operand`. Numbers for `>=/>/<=/<`;
    `==/!=` compare value ↔ operand (bareword → string, e.g. `critical`).
  - **conjunction**: `AND` only (the corpus uses neither `OR` nor
    parentheses nor negation beyond `!=`). A rule = conjunction of all its
    terms.

  Known limitation (outside the canon corpus): a multi-word RHS operand
  (`severity_max != very critical`) is captured as a single bareword
  `"very critical"` — bounded to the current corpus (single-word/number
  operands). To be hardened if a future workflow introduces operands with
  spaces.

  ## Fail-closed

  A referenced fact **absent** from the outputs, or an incompatible type (e.g. `>=`
  on a non-number), renders the predicate **false** — never a silent pass on
  missing evidence. The engine is mechanical: it fetches nothing, it reads `outputs`.

  ## Out-of-scope (not decided here)

  The gate's adjacent orchestration (`human_approval_required`)
  is NOT carried by this evaluator — it does ONLY `rule_string → bool`.
  The mapping to `:pass`/`:fail`/`:human_approval`/`:dispatch_gatekeeper` (including the
  refusal to auto-approve a `human_approval_required` gate) is in `Fleet.Workflow.Gates`.

  **Last revised**: 2026-07-18
  """

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

  # TOTAL fail-closed clause. The hard gate v2.5 applies `eval?` to EVERY item of
  # `rules` without guaranteeing it is a string: known asymmetry with the terminal
  # gate, which filters its non-string items upstream (`Enum.all?(rules, &is_binary/1)`).
  # A non-string `rule` (an UNSCHEMATIZED override — an in-memory workflow_map that bypassed the
  # loader's schema; there is NO v1 input, a v1 YAML fails the v2.5 schema before normalize)
  # — or non-map `outputs` — renders `false`:
  # the hard gate FAILS (`Enum.all?` becomes false → `{:fail, …}` in Gates), NEVER a
  # FunctionClauseError that would bubble up and crash the StepRunConsumer (singleton). The eval
  # is made TOTAL, symmetric with the terminal's fail-closed catch-all.
  def eval?(_rule, _outputs), do: false

  defp eval_term(term, outputs) do
    case parse(term) do
      {:cmp, lhs, op, operand} -> compare(Map.get(outputs, lhs, :__absent__), op, operand)
      {:atom, id} -> Map.get(outputs, id) == true
    end
  end

  # "identifier op operand" → {:cmp, ...} ; otherwise bare identifier → {:atom, id}.
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

  # Fail-closed: fact absent OR present-as-nil → predicate false (no pass on
  # missing evidence). The nil case is critical for `!=`: `nil != "critical"`
  # would be `true` in bare Elixir — we neutralize it (nil ≡ absent).
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

  # Incompatible type (e.g. `>=` on a non-number) → fail-closed.
  defp compare(_lhs, _op, _operand), do: false
end
