defmodule Fleet.Workflow.GatesTest do
  # async: Gates.evaluate/3 is a pure function (no application env, no global state).
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Gates

  describe "evaluate/3 — nil / absent gate" do
    test "nil gate → :pass" do
      assert Gates.evaluate(%{"gate" => nil}, %{}, %{}) == :pass
    end

    test "absent gate → :pass" do
      assert Gates.evaluate(%{"role" => "x"}, %{}, %{}) == :pass
    end
  end

  describe "evaluate/3 — soft (pure decision → gatekeeper dispatch)" do
    test "soft gate → {:dispatch_gatekeeper, kind: :soft} (Gates pure, no spawn nor retry)" do
      step = %{"gate" => %{"type" => "soft"}}
      assert {:dispatch_gatekeeper, %{kind: :soft}} = Gates.evaluate(step, %{}, %{user: "test"})
    end
  end

  describe "evaluate/3 — string rules (R3)" do
    test "hard: all predicates true → :pass" do
      step = %{
        "gate" => %{"type" => "hard", "rules" => ["all_tests_pass", "tdd_iron_law_respected"]}
      }

      assert :pass =
               Gates.evaluate(
                 step,
                 %{"all_tests_pass" => true, "tdd_iron_law_respected" => true},
                 %{}
               )
    end

    test "hard: one false predicate → {:fail}" do
      step = %{"gate" => %{"type" => "hard", "rules" => ["all_tests_pass"]}}
      assert {:fail, _} = Gates.evaluate(step, %{"all_tests_pass" => false}, %{})
    end

    test "hard: EMPTY rules → {:fail} (enforcing nothing = fail-closed, never :pass by vacuity)" do
      # Soft-pass hole #4: `Enum.all?([]) == true` → a hard gate with empty rules passed while
      # validating NOTHING (a gate meant to block — all_tests_pass, severity != critical — crossed
      # empty-handed). A hard gate without rules is MALFORMED → {:fail} via the fail-closed
      # catch-all, never a :pass by vacuity.
      step = %{"gate" => %{"type" => "hard", "rules" => []}}
      assert {:fail, _} = Gates.evaluate(step, %{}, %{})
    end

    test "terminal: predicates true without human approval → :pass" do
      step = %{"gate" => %{"type" => "terminal", "rules" => ["severity_max != critical"]}}
      assert :pass = Gates.evaluate(step, %{"severity_max" => "important"}, %{})
    end

    test "terminal: one false predicate → {:fail}" do
      step = %{"gate" => %{"type" => "terminal", "rules" => ["severity_max != critical"]}}
      assert {:fail, _} = Gates.evaluate(step, %{"severity_max" => "critical"}, %{})
    end

    test "terminal human_approval_required (predicates OK) → {:human_approval, _} (escalation, not auto-pass)" do
      # D2: verdict DISTINCT from {:fail} — a human approval is not a gate failure, it is an
      # escalation (the rail routes to await_arch directly). Fail-closed preserved: never a
      # silent :pass.
      step = %{
        "gate" => %{
          "type" => "terminal",
          "human_approval_required" => true,
          "rules" => ["spec_doc_exists"]
        }
      }

      assert {:human_approval, reason} = Gates.evaluate(step, %{"spec_doc_exists" => true}, %{})
      assert reason =~ "human_approval_required"
    end

    test "terminal WITHOUT rules key + human_approval (canon `finish` gate) → {:human_approval, _}, no crash" do
      # standard-qa `finish`: terminal + human_approval, NO rules.
      step = %{"gate" => %{"type" => "terminal", "human_approval_required" => true}}
      assert {:human_approval, reason} = Gates.evaluate(step, %{}, %{})
      assert reason =~ "human_approval_required"
    end

    test "terminal rules:[] + human_approval → {:human_approval, _} (NEVER a silent :pass)" do
      step = %{
        "gate" => %{"type" => "terminal", "rules" => [], "human_approval_required" => true}
      }

      assert {:human_approval, reason} = Gates.evaluate(step, %{}, %{})
      assert reason =~ "human_approval_required"
    end

    test "terminal WITHOUT rules nor human_approval → :pass (degenerate, nothing to judge)" do
      step = %{"gate" => %{"type" => "terminal"}}
      assert :pass = Gates.evaluate(step, %{}, %{})
    end
  end

  describe "MA-11 — closed sum: malformed gate → {:fail} fail-closed (NO crash)" do
    test "hard WITHOUT rule nor rules → {:fail} (was a FunctionClauseError → singleton crash)" do
      # Without the catch-all: no clause matched `{type:hard}` without `rule`/`rules`
      # → FunctionClauseError bubbled up to the StepRunConsumer (singleton) → crash.
      step = %{"gate" => %{"type" => "hard"}}
      assert {:fail, reason} = Gates.evaluate(step, %{"x" => 1}, %{})
      assert reason =~ "malformed"
    end

    test "hard with NON-LIST rules (string) → {:fail}, no BadMapError" do
      step = %{"gate" => %{"type" => "hard", "rules" => "all_tests_pass"}}
      assert {:fail, _} = Gates.evaluate(step, %{}, %{})
    end

    test "UNKNOWN type → {:fail} fail-closed (never a silent :pass)" do
      step = %{"gate" => %{"type" => "weird"}}
      assert {:fail, _} = Gates.evaluate(step, %{}, %{})
    end

    test "NON-MAP gate (string) → {:fail}, no crash" do
      step = %{"gate" => "always"}
      assert {:fail, _} = Gates.evaluate(step, %{}, %{})
    end

    test "terminal with NON-LIST rules (map) → {:fail}, no BadMapError (MA-11 variant)" do
      step = %{"gate" => %{"type" => "terminal", "rules" => %{"a" => 1}}}
      assert {:fail, _} = Gates.evaluate(step, %{}, %{})
    end

    test "hard with rules = LIST of NON-STRING items (maps) → {:fail}, no FunctionClauseError (singleton crash)" do
      # Asymmetry: the hard gate (`is_list(rules)`) called `Predicate.eval?` on EACH item
      # WITHOUT filtering non-strings (the terminal one filters via
      # `Enum.all?(rules, &is_binary/1)`). A NON-SCHEMATIZED override (in-memory workflow_map
      # bypassing the loader's schema — there is no flat entry point: an envelope-less YAML fails the
      # schema before normalize) carrying a hard gate with `rules` = list of maps raised
      # FunctionClauseError inside Predicate → it bubbled up unwrapped to the StepRunConsumer
      # (singleton) → crash. The total `Predicate.eval?/2` net (non-string item → false) makes
      # the gate fail-closed.
      step = %{
        "gate" => %{"type" => "hard", "rules" => [%{"name" => "r1", "match" => %{"a" => 1}}]}
      }

      assert {:fail, _} = Gates.evaluate(step, %{"a" => 1}, %{})
    end

    test "the real crash: no gate shape raises — evaluate is TOTAL" do
      for gate <- [
            %{"type" => "hard"},
            %{"type" => "hard", "rules" => [%{"x" => 1}]},
            %{"type" => "hard", "rules" => [42, "all_tests_pass"]},
            %{"type" => "x"},
            "str",
            42,
            %{},
            %{"rules" => 1}
          ] do
        result = Gates.evaluate(%{"gate" => gate}, %{"out" => 1}, %{})

        assert match?(:pass, result) or match?({:fail, _}, result) or
                 match?({:dispatch_gatekeeper, _}, result),
               "gate #{inspect(gate)} returned #{inspect(result)} (should be total, never a raise)"
      end
    end
  end

  describe "shape before verdict — the hard/terminal asymmetry is gone (vanille B3)" do
    defp hard(rules), do: %{"gate" => %{"type" => "hard", "rules" => rules}}
    defp terminal(rules), do: %{"gate" => %{"type" => "terminal", "rules" => rules}}

    test "a hard gate with a non-string rule is refused BY NAME, not as an unsatisfied predicate" do
      assert {:fail, msg} = Gates.evaluate(hard([42]), %{"all_tests_pass" => true}, %{})
      assert msg =~ "malformed hard gate"
      assert msg =~ "shape rejected"
      refute msg =~ "unsatisfied"
    end

    test "the two gate types now answer the SAME way to the same malformed shape" do
      {:fail, hard_msg} = Gates.evaluate(hard([%{}]), %{}, %{})
      {:fail, term_msg} = Gates.evaluate(terminal([%{}]), %{}, %{})

      assert hard_msg =~ "must be a list of strings (shape rejected)"
      assert term_msg =~ "must be a list of strings (shape rejected)"
    end

    test "INVERSE TWIN — a genuinely unsatisfied string rule keeps its OWN message" do
      # The distinction is the whole point: "the work did not satisfy the rule" sends a reader to
      # the deliverable, "the shape is wrong" sends them to the card. Collapsing them sent every
      # reader to the wrong place.
      assert {:fail, msg} =
               Gates.evaluate(hard(["all_tests_pass"]), %{"all_tests_pass" => false}, %{})

      assert msg =~ "unsatisfied string rule"
      refute msg =~ "malformed"
    end

    test "INVERSE TWIN — a satisfied hard gate still passes" do
      assert :pass = Gates.evaluate(hard(["all_tests_pass"]), %{"all_tests_pass" => true}, %{})
    end
  end
end
