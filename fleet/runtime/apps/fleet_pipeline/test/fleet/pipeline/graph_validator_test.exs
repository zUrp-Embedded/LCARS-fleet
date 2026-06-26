defmodule Fleet.Pipeline.GraphValidatorTest do
  @moduledoc """
  Linter de graphe PUR (data → décision), testé sans fichier (`async: true`).
  Couvre chaque invariant : carte bien formée → :ok ; chaque violation → son `kind`.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pipeline.GraphValidator

  # Spec de stage minimale. `needs` omis = racine (le Loader normalise `needs` absent → []).
  defp stage(needs \\ nil) do
    base = %{"role" => "noop", "profile" => "empty"}
    if needs, do: Map.put(base, "needs", needs), else: base
  end

  describe "carte bien formée → :ok" do
    test "stage unique (racine == terminal)" do
      assert GraphValidator.validate(%{"only" => stage()}) == :ok
    end

    test "chaîne linéaire racine → terminal" do
      stages = %{
        "a" => stage(),
        "b" => stage(["a"]),
        "c" => stage(["b"])
      }

      assert GraphValidator.validate(stages) == :ok
    end
  end

  describe "racine" do
    test "0 racine (graphe entièrement cyclique) → :no_root" do
      stages = %{"a" => stage(["b"]), "b" => stage(["a"])}
      assert {:error, {:no_root, _}} = GraphValidator.validate(stages)
    end

    test "≥2 racines → :multiple_roots (avec les noms)" do
      stages = %{"a" => stage(), "b" => stage(), "c" => stage(["a", "b"])}
      assert {:error, {:multiple_roots, %{roots: ["a", "b"]}}} = GraphValidator.validate(stages)
    end
  end

  describe "needs fantôme (arête fantôme)" do
    test "needs réfère un stage non déclaré → :phantom_edge (stage + needs fautif)" do
      stages = %{"a" => stage(), "b" => stage(["implment"])}

      assert {:error, {:phantom_edge, %{stage: "b", needs: "implment"}}} =
               GraphValidator.validate(stages)
    end
  end

  describe "acyclicité" do
    test "cycle SUR la chaîne (atteignable depuis la racine) → :cycle" do
      # racine r → a → b → a (b boucle sur a). r est racine ; a,b atteignables ; cycle a↔b.
      stages = %{
        "r" => stage(),
        "a" => stage(["r", "b"]),
        "b" => stage(["a"])
      }

      assert {:error, {:cycle, %{stages: cyclic}}} = GraphValidator.validate(stages)
      assert "a" in cyclic and "b" in cyclic
    end

    test "terminal absent (la chaîne boucle, aucun stage sans successeur) → rejet" do
      # Pour ce runtime séquentiel, « aucun terminal atteignable » == « cycle » :
      # une chaîne r → a → b → a n'a aucun stage terminal. Rejetée comme :cycle.
      stages = %{"r" => stage(), "a" => stage(["r", "b"]), "b" => stage(["a"])}
      assert {:error, {:cycle, _}} = GraphValidator.validate(stages)
    end
  end

  describe "atteignabilité" do
    test "composant orphelin (déconnecté de la racine) → :unreachable" do
      # r seul = chaîne principale ; x↔y forment un blob déconnecté (non atteignable
      # depuis r). Diagnostiqué :unreachable (câblage manquant) AVANT l'acyclicité.
      stages = %{
        "r" => stage(),
        "x" => stage(["y"]),
        "y" => stage(["x"])
      }

      assert {:error, {:unreachable, %{stages: orphans}}} = GraphValidator.validate(stages)
      assert "x" in orphans and "y" in orphans
    end
  end

  describe "fan-out (branche parallèle, hors-scope séquentiel)" do
    test "un stage avec ≥2 successeurs → :fan_out" do
      # a a deux successeurs (b et c) → branche parallèle, rejetée (runtime séquentiel).
      stages = %{
        "a" => stage(),
        "b" => stage(["a"]),
        "c" => stage(["a"])
      }

      assert {:error, {:fan_out, %{stage: "a", successors: ["b", "c"]}}} =
               GraphValidator.validate(stages)
    end
  end

  describe "describe/1 — message lisible par invariant" do
    test "phantom_edge nomme le stage et le needs fautif" do
      msg = GraphValidator.describe({:phantom_edge, %{stage: "build", needs: "foo"}})
      assert msg =~ "arête fantôme"
      assert msg =~ "build"
      assert msg =~ "foo"
    end
  end
end
