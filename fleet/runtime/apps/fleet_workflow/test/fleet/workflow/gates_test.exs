defmodule Fleet.Workflow.GatesTest do
  # async : Gates.evaluate/3 est une fonction pure (aucun env applicatif, aucun état global).
  use ExUnit.Case, async: true

  alias Fleet.Workflow.Gates

  describe "evaluate/3 — nil / absent gate" do
    test "gate nil → :pass" do
      assert Gates.evaluate(%{"gate" => nil}, %{}, %{}) == :pass
    end

    test "gate absent → :pass" do
      assert Gates.evaluate(%{"role" => "x"}, %{}, %{}) == :pass
    end
  end

  describe "evaluate/3 — soft (décision pure → dispatch gatekeeper)" do
    test "soft gate → {:dispatch_gatekeeper, kind: :soft} (Gates pur, pas de spawn ni retry)" do
      step = %{"gate" => %{"type" => "soft"}}
      assert {:dispatch_gatekeeper, %{kind: :soft}} = Gates.evaluate(step, %{}, %{user: "test"})
    end
  end

  describe "evaluate/3 — v2.5 string rules (R3)" do
    test "hard : tous les prédicats vrais → :pass" do
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

    test "hard : un prédicat faux → {:fail}" do
      step = %{"gate" => %{"type" => "hard", "rules" => ["all_tests_pass"]}}
      assert {:fail, _} = Gates.evaluate(step, %{"all_tests_pass" => false}, %{})
    end

    test "terminal : prédicats vrais sans aval humain → :pass" do
      step = %{"gate" => %{"type" => "terminal", "rules" => ["severity_max != critical"]}}
      assert :pass = Gates.evaluate(step, %{"severity_max" => "important"}, %{})
    end

    test "terminal : un prédicat faux → {:fail}" do
      step = %{"gate" => %{"type" => "terminal", "rules" => ["severity_max != critical"]}}
      assert {:fail, _} = Gates.evaluate(step, %{"severity_max" => "critical"}, %{})
    end

    test "terminal human_approval_required (prédicats OK) → {:human_approval, _} (escalade, pas auto-pass)" do
      # D2 : verdict DISTINCT de {:fail} — un aval humain n'est pas un échec de gate, c'est une escalade
      # (le rail route vers await_arch directement). Fail-closed préservé : jamais :pass silencieux.
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

    test "terminal SANS clé rules + human_approval (gate `finish` canon) → {:human_approval, _}, pas de crash" do
      # standard-qa `finish` : terminal + human_approval, AUCUNE rules.
      step = %{"gate" => %{"type" => "terminal", "human_approval_required" => true}}
      assert {:human_approval, reason} = Gates.evaluate(step, %{}, %{})
      assert reason =~ "human_approval_required"
    end

    test "terminal rules:[] + human_approval → {:human_approval, _} (JAMAIS :pass silencieux)" do
      step = %{
        "gate" => %{"type" => "terminal", "rules" => [], "human_approval_required" => true}
      }

      assert {:human_approval, reason} = Gates.evaluate(step, %{}, %{})
      assert reason =~ "human_approval_required"
    end

    test "terminal SANS rules ni human_approval → :pass (dégénéré, rien à juger)" do
      step = %{"gate" => %{"type" => "terminal"}}
      assert :pass = Gates.evaluate(step, %{}, %{})
    end
  end

  describe "MA-11 — somme fermée : gate malformée → {:fail} fail-closed (PAS de crash)" do
    test "hard SANS rule ni rules → {:fail} (était un FunctionClauseError → crash singleton)" do
      # Avant le catch-all : aucune clause ne matchait `{type:hard}` sans `rule`/`rules`
      # → FunctionClauseError remontait au StepRunConsumer (singleton) → crash.
      step = %{"gate" => %{"type" => "hard"}}
      assert {:fail, reason} = Gates.evaluate(step, %{"x" => 1}, %{})
      assert reason =~ "malformed"
    end

    test "hard avec rules NON-LISTE (string) → {:fail}, pas BadMapError" do
      step = %{"gate" => %{"type" => "hard", "rules" => "all_tests_pass"}}
      assert {:fail, _} = Gates.evaluate(step, %{}, %{})
    end

    test "type INCONNU → {:fail} fail-closed (jamais :pass silencieux)" do
      step = %{"gate" => %{"type" => "bizarre"}}
      assert {:fail, _} = Gates.evaluate(step, %{}, %{})
    end

    test "gate NON-MAP (string) → {:fail}, pas de crash" do
      step = %{"gate" => "always"}
      assert {:fail, _} = Gates.evaluate(step, %{}, %{})
    end

    test "terminal avec rules NON-LISTE (map) → {:fail}, pas BadMapError (variante MA-11)" do
      step = %{"gate" => %{"type" => "terminal", "rules" => %{"a" => 1}}}
      assert {:fail, _} = Gates.evaluate(step, %{}, %{})
    end

    test "hard avec rules = LISTE d'items NON-STRING (maps) → {:fail}, pas FunctionClauseError (crash singleton)" do
      # Asymétrie : le hard gate v2.5 (`is_list(rules)`) appelait `Predicate.eval?` sur
      # CHAQUE item SANS filtrer les non-strings (le terminal, lui, filtre via
      # `Enum.all?(rules, &is_binary/1)`). Une workflow_map v1 — ou un override non schématisé —
      # portant un hard gate à `rules` = liste de maps levait FunctionClauseError dans
      # Predicate → ça remontait non-wrappé au StepRunConsumer (singleton) → crash. Le filet
      # `Predicate.eval?/2` total (item non-string → false) rend la gate fail-closed.
      step = %{
        "gate" => %{"type" => "hard", "rules" => [%{"name" => "r1", "match" => %{"a" => 1}}]}
      }

      assert {:fail, _} = Gates.evaluate(step, %{"a" => 1}, %{})
    end

    test "le crash réel : aucune forme de gate ne lève — evaluate est TOTALE" do
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
               "gate #{inspect(gate)} a rendu #{inspect(result)} (devrait être total, jamais un raise)"
      end
    end
  end
end
