defmodule Fleet.Pilot.CarteNavTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.CarteNav

  # Carte linéaire type poc-cycle (format Loader : stages map keyed-by-name, clés string)
  defp poc_cycle do
    %{
      "name" => "poc-cycle",
      "stages" => %{
        "triage" => %{"role" => "architect", "needs" => []},
        "refine" => %{"role" => "consultant", "needs" => ["triage"]},
        "build" => %{"role" => "engineer", "needs" => ["refine"], "gate" => %{"type" => "hard"}},
        "review" => %{"role" => "reviewer", "needs" => ["build"]},
        "seal" => %{"role" => "starfleet", "needs" => ["review"]}
      }
    }
  end

  describe "first_stage/1" do
    test "racine unique (needs: []) → {:ok, {name, role}}" do
      assert {:ok, {"triage", "architect"}} = CarteNav.first_stage(poc_cycle())
    end

    test "aucune racine → {:error, :no_root}" do
      carte = %{
        "stages" => %{
          "a" => %{"role" => "x", "needs" => ["b"]},
          "b" => %{"role" => "y", "needs" => ["a"]}
        }
      }

      assert {:error, :no_root} = CarteNav.first_stage(carte)
    end

    test "≥2 racines (entrée parallèle) → {:error, :multiple_roots}" do
      carte = %{
        "stages" => %{
          "a" => %{"role" => "x", "needs" => []},
          "b" => %{"role" => "y", "needs" => []}
        }
      }

      assert {:error, :multiple_roots} = CarteNav.first_stage(carte)
    end
  end

  describe "next_stage/2 — chaîne linéaire" do
    test "milieu de chaîne → successeur" do
      assert {:ok, {"refine", "consultant"}} = CarteNav.next_stage(poc_cycle(), "triage")
      assert {:ok, {"build", "engineer"}} = CarteNav.next_stage(poc_cycle(), "refine")
      assert {:ok, {"review", "reviewer"}} = CarteNav.next_stage(poc_cycle(), "build")
      assert {:ok, {"seal", "starfleet"}} = CarteNav.next_stage(poc_cycle(), "review")
    end

    test "dernier stage → :terminal" do
      assert :terminal = CarteNav.next_stage(poc_cycle(), "seal")
    end

    test "stage inconnu → {:error, :unknown_stage}" do
      assert {:error, :unknown_stage} = CarteNav.next_stage(poc_cycle(), "nope")
    end

    test "≥2 successeurs (DAG, hors-scope) → {:error, :dag_not_supported}" do
      carte = %{
        "stages" => %{
          "root" => %{"role" => "a", "needs" => []},
          "b1" => %{"role" => "b", "needs" => ["root"]},
          "b2" => %{"role" => "c", "needs" => ["root"]}
        }
      }

      assert {:error, :dag_not_supported} = CarteNav.next_stage(carte, "root")
    end
  end

  describe "stage_role/2 + stage_spec/2" do
    test "rôle + spec d'un stage connu" do
      assert {:ok, "engineer"} = CarteNav.stage_role(poc_cycle(), "build")
      assert {:ok, %{"gate" => %{"type" => "hard"}}} = CarteNav.stage_spec(poc_cycle(), "build")
    end

    test "rôle d'un même rôle sur 2 stages — le NOM désambiguïse (le wrinkle DN §8)" do
      # standard-qa : architect sur brainstorm ET plan
      carte = %{
        "stages" => %{
          "brainstorm" => %{"role" => "architect", "needs" => []},
          "plan" => %{"role" => "architect", "needs" => ["brainstorm"]}
        }
      }

      # par nom : sans ambiguïté
      assert {:ok, {"plan", "architect"}} = CarteNav.next_stage(carte, "brainstorm")
      assert :terminal = CarteNav.next_stage(carte, "plan")
    end

    test "stage inconnu → :error" do
      assert :error = CarteNav.stage_role(poc_cycle(), "nope")
      assert :error = CarteNav.stage_spec(poc_cycle(), "nope")
    end
  end

  # B (§L441) — les tests de `validate_explicit_stage/1` (biconditionnelle soft⟺gatekeeper,
  # A2.3b) sont RETIRÉS avec la fonction : une gate soft sur un stage métier est légitime
  # (escalade gatekeeper), pas une carte malformée. cf. step_run_consumer_gate_test (escalade B).
end
