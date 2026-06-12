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

  describe "evaluate/3 — hard" do
    test "rule match outputs → :pass" do
      stage = %{"gate" => %{"type" => "hard", "rule" => %{"status" => "ok"}}}
      assert Gates.evaluate(stage, %{"status" => "ok", "extra" => 1}, %{}) == :pass
    end

    test "rule mismatch → {:fail, _}" do
      stage = %{"gate" => %{"type" => "hard", "rule" => %{"status" => "ok"}}}
      assert {:fail, "hard gate rule mismatch"} = Gates.evaluate(stage, %{"status" => "ko"}, %{})
    end

    test "nested rule match" do
      stage = %{
        "gate" => %{
          "type" => "hard",
          "rule" => %{"data" => %{"count" => 3}}
        }
      }

      assert Gates.evaluate(stage, %{"data" => %{"count" => 3, "extra" => true}}, %{}) ==
               :pass
    end
  end

  describe "evaluate/3 — soft (décision pure → dispatch gatekeeper)" do
    test "soft gate → {:dispatch_gatekeeper, kind: :soft} (Gates pur, pas de spawn ni retry)" do
      stage = %{"gate" => %{"type" => "soft"}}
      assert {:dispatch_gatekeeper, %{kind: :soft}} = Gates.evaluate(stage, %{}, %{user: "test"})
    end
  end

  describe "evaluate/3 — terminal" do
    test "toutes règles match → :pass" do
      stage = %{
        "gate" => %{
          "type" => "terminal",
          "rules" => [
            %{"name" => "r1", "match" => %{"a" => 1}},
            %{"name" => "r2", "match" => %{"b" => 2}}
          ]
        }
      }

      assert Gates.evaluate(stage, %{"a" => 1, "b" => 2}, %{}) == :pass
    end

    test "règle required mismatch → {:fail, _}" do
      stage = %{
        "gate" => %{
          "type" => "terminal",
          "rules" => [
            %{"name" => "must_have_status", "required" => true, "match" => %{"status" => "ok"}}
          ]
        }
      }

      assert {:fail, msg} = Gates.evaluate(stage, %{"status" => "ko"}, %{})
      assert msg =~ "must_have_status"
    end

    test "règle non-required mismatch → {:dispatch_gatekeeper, kind: :terminal}" do
      stage = %{
        "gate" => %{
          "type" => "terminal",
          "rules" => [
            %{"name" => "soft_check", "required" => false, "match" => %{"clean" => true}}
          ]
        }
      }

      assert {:dispatch_gatekeeper, %{kind: :terminal}} =
               Gates.evaluate(stage, %{"clean" => false}, %{ticket_id: "t#1"})
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
end
