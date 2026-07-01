defmodule Fleet.Pipeline.GatesTest do
  use ExUnit.Case, async: false

  alias Fleet.Pipeline.Gates

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
      stage = %{"gate" => %{"type" => "soft"}}
      assert {:dispatch_gatekeeper, %{kind: :soft}} = Gates.evaluate(stage, %{}, %{user: "test"})
    end
  end

  describe "evaluate/3 — v2.5 string rules (R3)" do
    test "hard : tous les prédicats vrais → :pass" do
      stage = %{
        "gate" => %{"type" => "hard", "rules" => ["all_tests_pass", "tdd_iron_law_respected"]}
      }

      assert :pass =
               Gates.evaluate(
                 stage,
                 %{"all_tests_pass" => true, "tdd_iron_law_respected" => true},
                 %{}
               )
    end

    test "hard : un prédicat faux → {:fail}" do
      stage = %{"gate" => %{"type" => "hard", "rules" => ["all_tests_pass"]}}
      assert {:fail, _} = Gates.evaluate(stage, %{"all_tests_pass" => false}, %{})
    end

    test "terminal : prédicats vrais sans aval humain → :pass" do
      stage = %{"gate" => %{"type" => "terminal", "rules" => ["severity_max != critical"]}}
      assert :pass = Gates.evaluate(stage, %{"severity_max" => "important"}, %{})
    end

    test "terminal : un prédicat faux → {:fail}" do
      stage = %{"gate" => %{"type" => "terminal", "rules" => ["severity_max != critical"]}}
      assert {:fail, _} = Gates.evaluate(stage, %{"severity_max" => "critical"}, %{})
    end

    test "terminal human_approval_required (prédicats OK) → {:fail} fail-closed (pas d'auto-pass)" do
      stage = %{
        "gate" => %{
          "type" => "terminal",
          "human_approval_required" => true,
          "rules" => ["spec_doc_exists"]
        }
      }

      assert {:fail, reason} = Gates.evaluate(stage, %{"spec_doc_exists" => true}, %{})
      assert reason =~ "human_approval_required"
    end

    test "terminal SANS clé rules + human_approval (gate `finish` canon) → {:fail}, pas de crash" do
      # standard-qa `finish` : terminal + human_approval, AUCUNE rules.
      stage = %{"gate" => %{"type" => "terminal", "human_approval_required" => true}}
      assert {:fail, reason} = Gates.evaluate(stage, %{}, %{})
      assert reason =~ "human_approval_required"
    end

    test "terminal rules:[] + human_approval → {:fail} (JAMAIS :pass silencieux)" do
      stage = %{
        "gate" => %{"type" => "terminal", "rules" => [], "human_approval_required" => true}
      }

      assert {:fail, reason} = Gates.evaluate(stage, %{}, %{})
      assert reason =~ "human_approval_required"
    end

    test "terminal SANS rules ni human_approval → :pass (dégénéré, rien à juger)" do
      stage = %{"gate" => %{"type" => "terminal"}}
      assert :pass = Gates.evaluate(stage, %{}, %{})
    end
  end

  describe "MA-11 — somme fermée : gate malformée → {:fail} fail-closed (PAS de crash)" do
    test "hard SANS rule ni rules → {:fail} (était un FunctionClauseError → crash singleton)" do
      # Avant le catch-all : aucune clause ne matchait `{type:hard}` sans `rule`/`rules`
      # → FunctionClauseError remontait au StepRunConsumer (singleton) → crash.
      stage = %{"gate" => %{"type" => "hard"}}
      assert {:fail, reason} = Gates.evaluate(stage, %{"x" => 1}, %{})
      assert reason =~ "malformée"
    end

    test "hard avec rules NON-LISTE (string) → {:fail}, pas BadMapError" do
      stage = %{"gate" => %{"type" => "hard", "rules" => "all_tests_pass"}}
      assert {:fail, _} = Gates.evaluate(stage, %{}, %{})
    end

    test "type INCONNU → {:fail} fail-closed (jamais :pass silencieux)" do
      stage = %{"gate" => %{"type" => "bizarre"}}
      assert {:fail, _} = Gates.evaluate(stage, %{}, %{})
    end

    test "gate NON-MAP (string) → {:fail}, pas de crash" do
      stage = %{"gate" => "always"}
      assert {:fail, _} = Gates.evaluate(stage, %{}, %{})
    end

    test "terminal avec rules NON-LISTE (map) → {:fail}, pas BadMapError (variante MA-11)" do
      stage = %{"gate" => %{"type" => "terminal", "rules" => %{"a" => 1}}}
      assert {:fail, _} = Gates.evaluate(stage, %{}, %{})
    end

    test "hard avec rules = LISTE d'items NON-STRING (maps) → {:fail}, pas FunctionClauseError (crash singleton)" do
      # Asymétrie : le hard gate v2.5 (`is_list(rules)`) appelait `Predicate.eval?` sur
      # CHAQUE item SANS filtrer les non-strings (le terminal, lui, filtre via
      # `Enum.all?(rules, &is_binary/1)`). Une carte v1 — ou un override non schématisé —
      # portant un hard gate à `rules` = liste de maps levait FunctionClauseError dans
      # Predicate → ça remontait non-wrappé au StepRunConsumer (singleton) → crash. Le filet
      # `Predicate.eval?/2` total (item non-string → false) rend la gate fail-closed.
      stage = %{
        "gate" => %{"type" => "hard", "rules" => [%{"name" => "r1", "match" => %{"a" => 1}}]}
      }

      assert {:fail, _} = Gates.evaluate(stage, %{"a" => 1}, %{})
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
