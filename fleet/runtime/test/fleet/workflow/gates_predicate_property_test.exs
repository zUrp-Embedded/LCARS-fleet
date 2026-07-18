defmodule Fleet.Workflow.Gates.PredicatePropertyTest do
  @moduledoc """
  Property-based proof of the gate rule evaluator. `gates_predicate_test.exs`
  proves totality over the TYPES (non-string rule, non-map outputs → false); it proves
  NOTHING about the CONTENT — a malformed rule string remains an uncovered path, and that
  is where the risk lives.

  Why content totality matters: `Gates` applies `eval?` to every item of `rules`
  from `Fleet.Workflow.StepRunConsumer`, a SINGLETON. An exception raised here (regex,
  arithmetic, protocol) does not "fail the gate": it KILLS the consumer, and the whole
  step pipeline stops. The contract is therefore: `rule_string × outputs → boolean()`, TOTAL,
  fail-closed — never a raise, never a pass on absent evidence.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Fleet.Workflow.Gates.Predicate

  # The operators from Predicate's @ops — the supported grammar, locked here.
  @ops ~w(>= <= == != > <)

  # ── generators ──

  # Identifier: `\w` charset (the one of the `^(\w+)\s*…` parser).
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

  # Adversarial `outputs`: keys present/absent, values of every type the pod
  # can self-report (and `nil`, the documented `!=` trap).
  defp outputs_gen do
    map_of(
      one_of([identifier(), string(:printable, max_length: 6)]),
      one_of([boolean(), integer(), float(), string(:printable, max_length: 6), constant(nil)]),
      max_length: 6
    )
  end

  # ── P1 — CONTENT TOTALITY ──

  # INVARIANT: for ANY rule string (well-formed OR printable noise) and ANY outputs (absent
  # keys, values of any type, nil), `eval?/2` returns a boolean and NEVER raises.
  # WHY: `eval?` runs inside the StepRunConsumer, a singleton. A raise is not a failing gate —
  # it is the consumer DYING and the entire step pipeline stopping. Totality is only proven
  # on the TYPES (non-string rule) elsewhere; here we prove it on the CONTENT, which is the
  # real input domain.
  property "P1 TOTALITY — any rule string × any outputs → boolean(), never a raise" do
    check all(rule <- any_rule(), outputs <- outputs_gen(), max_runs: 400) do
      assert is_boolean(Predicate.eval?(rule, outputs)),
             "eval?(#{inspect(rule)}, #{inspect(outputs)}) must return a boolean"
    end
  end

  # ── P2 — FAIL-CLOSED ──

  # INVARIANT: for EACH supported operator, an identifier ABSENT from the outputs → false.
  # Same for the atom form (bare identifier).
  # WHY: this is the gate's cardinal rule — "no pass on absent evidence". A `!=` is the
  # concrete trap: `nil != "critical"` is `true` in bare Elixir, so a fact NOT REPORTED
  # by the pod would validate the gate `severity_max != critical` and let never-audited
  # code through. The property covers all 6 operators, not just the one in mind.
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

  # INVARIANT: on two integers, `eval?("id OP n", %{id => m})` == `m OP n` in native Elixir.
  # WHY: fail-closed totality could be achieved TRIVIALLY by a constant `false` — that test
  # would pass. The oracle proves fail-closed did not eat the USEFUL behavior: a
  # `tasks_count >= 1` gate must still be able to say `true`.
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

  # INVARIANT: `AND` is the exact boolean conjunction of the terms — evaluating the composed
  # rule == evaluating each term and `and`-ing them.
  # WHY: an `AND` that short-circuited wrongly (or swallowed an unparsed term) would turn a
  # 3-rule gate GREEN when only one of its terms holds. The composition is load-bearing,
  # not just each isolated term.
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
