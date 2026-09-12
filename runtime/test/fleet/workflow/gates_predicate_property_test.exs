defmodule Fleet.Workflow.Gates.PredicatePropertyTest do
  @moduledoc """
  Samples generated predicate rules and scalar output maps. Integer comparisons use
  a native Elixir oracle; absent/nil facts and conjunction have separate properties.
  Finite samples do not establish totality for all inputs.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Workflow.Gates.Predicate

  # The operators from Predicate's @ops — the supported grammar, locked here.
  @ops ~w(>= <= == != > <)

  # ── generators ──

  # Identifiers use a subset of the parser's word characters.
  defp identifier, do: string([?a..?z, ?_], min_length: 1, max_length: 8)

  # Operand as the parser sees it: integer, float, or bareword (string).
  defp operand do
    one_of([
      map(integer(), &to_string/1),
      map(float(), &to_string/1),
      string([?a..?z], min_length: 1, max_length: 8)
    ])
  end

  # WELL-FORMED term: comparison or bare atom.
  defp well_formed_term do
    one_of([
      gen all(id <- identifier(), op <- member_of(@ops), rhs <- operand()) do
        "#{id} #{op} #{rhs}"
      end,
      identifier()
    ])
  end

  # Well-formed rule: conjunction of terms joined by `AND`.
  defp well_formed_rule do
    map(list_of(well_formed_term(), min_length: 1, max_length: 4), &Enum.join(&1, " AND "))
  end

  # A rule as it can ACTUALLY arrive: well-formed, or printable noise
  # (hand-crafted workflow_map, unknown operator, multi-word RHS, dangling `AND`…).
  defp any_rule do
    one_of([
      well_formed_rule(),
      string(:printable, max_length: 40),
      member_of([
        "",
        "AND",
        " AND ",
        "x AND",
        "AND x",
        "x >=",
        ">= 3",
        "x >>= 3",
        "x == ",
        "x != very critical",
        "x >= NaN",
        "x >= 1e999",
        "x >= 0x10",
        "x >= --3",
        "1 >= x",
        "x.y >= 3",
        "x >= 3 AND AND y",
        "  ",
        "x\n>= 3"
      ])
    ])
  end

  # Scalar values only; nested lists/maps are not generated.
  defp outputs_gen do
    map_of(
      one_of([identifier(), string(:printable, max_length: 6)]),
      one_of([boolean(), integer(), float(), string(:printable, max_length: 6), constant(nil)]),
      max_length: 6
    )
  end

  # ── P1 — CONTENT TOTALITY ──

  # Sample generated rules, printable noise and scalar outputs.
  property "P1 TOTALITY — any rule string × any outputs → boolean(), never a raise" do
    check all(rule <- any_rule(), outputs <- outputs_gen(), max_runs: 400) do
      assert is_boolean(Predicate.eval?(rule, outputs)),
             "eval?(#{inspect(rule)}, #{inspect(outputs)}) must return a boolean"
    end
  end

  # ── P2 — FAIL-CLOSED ──

  # Absent and nil facts must fail even for !=, unlike native nil != string.
  property "P2 FAIL-CLOSED — identifier absent from outputs → false, for EVERY operator" do
    check all(
            outputs <- outputs_gen(),
            id <- identifier(),
            op <- member_of(@ops),
            rhs <- operand()
          ) do
      absent = Map.delete(outputs, id)

      refute Predicate.eval?("#{id} #{op} #{rhs}", absent),
             "absent fact + `#{op}` must be fail-closed"

      refute Predicate.eval?(id, absent), "absent atom must be fail-closed"

      # A fact PRESENT-AS-NIL is treated as absent (nil ≡ absent) — same requirement.
      refute Predicate.eval?("#{id} #{op} #{rhs}", Map.put(absent, id, nil))
      refute Predicate.eval?(id, Map.put(absent, id, nil))
    end
  end

  # ── Oracle: the numeric comparison does what it says ──

  # Independent integer oracle: successful verdicts rule out constant false.
  property "oracle — integer comparison: eval? ≡ the Elixir operator (all 6 ops, negatives included)" do
    check all(id <- identifier(), m <- integer(), n <- integer(), op <- member_of(@ops)) do
      expected =
        case op do
          ">=" -> m >= n
          "<=" -> m <= n
          ">" -> m > n
          "<" -> m < n
          "==" -> m == n
          "!=" -> m != n
        end

      assert Predicate.eval?("#{id} #{op} #{n}", %{id => m}) == expected,
             "eval?(#{inspect("#{id} #{op} #{n}")}, %{#{inspect(id)} => #{m}}) ≠ #{m} #{op} #{n}"
    end
  end

  # Checks composition against individual evaluation, not an independent parser.
  property "AND — the conjunction is exact (no term swallowed)" do
    check all(
            terms <- list_of(well_formed_term(), min_length: 2, max_length: 4),
            outputs <- outputs_gen()
          ) do
      expected = Enum.all?(terms, &Predicate.eval?(&1, outputs))
      assert Predicate.eval?(Enum.join(terms, " AND "), outputs) == expected
    end
  end
end
