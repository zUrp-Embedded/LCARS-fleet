defmodule Fleet.Pipeline.GraphValidatorTest do
  @moduledoc """
  Linter de graphe PUR (data → décision), testé sans fichier (`async: true`).
  Couvre chaque invariant : workflow_map bien formée → :ok ; chaque violation → son `kind`.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pipeline.GraphValidator

  # Spec de step minimale. `needs` omis = racine (le Loader normalise `needs` absent → []).
  defp step(needs \\ nil) do
    base = %{"role" => "noop", "profile" => "empty"}
    if needs, do: Map.put(base, "needs", needs), else: base
  end

  describe "workflow_map bien formée → :ok" do
    test "step unique (racine == terminal)" do
      assert GraphValidator.validate(%{"only" => step()}) == :ok
    end

    test "chaîne linéaire racine → terminal" do
      steps = %{
        "a" => step(),
        "b" => step(["a"]),
        "c" => step(["b"])
      }

      assert GraphValidator.validate(steps) == :ok
    end
  end

  describe "racine" do
    test "0 racine (graphe entièrement cyclique) → :no_root" do
      steps = %{"a" => step(["b"]), "b" => step(["a"])}
      assert {:error, {:no_root, _}} = GraphValidator.validate(steps)
    end

    test "≥2 racines → :multiple_roots (avec les noms)" do
      steps = %{"a" => step(), "b" => step(), "c" => step(["a", "b"])}
      assert {:error, {:multiple_roots, %{roots: ["a", "b"]}}} = GraphValidator.validate(steps)
    end
  end

  describe "needs fantôme (arête fantôme)" do
    test "needs réfère un step non déclaré → :phantom_edge (step + needs fautif)" do
      steps = %{"a" => step(), "b" => step(["implment"])}

      assert {:error, {:phantom_edge, %{step: "b", needs: "implment"}}} =
               GraphValidator.validate(steps)
    end
  end

  describe "acyclicité" do
    test "cycle SUR la chaîne (atteignable depuis la racine) → :cycle" do
      # racine r → a → b → a (b boucle sur a). r est racine ; a,b atteignables ; cycle a↔b.
      steps = %{
        "r" => step(),
        "a" => step(["r", "b"]),
        "b" => step(["a"])
      }

      assert {:error, {:cycle, %{steps: cyclic}}} = GraphValidator.validate(steps)
      assert "a" in cyclic and "b" in cyclic
    end

    test "terminal absent (la chaîne boucle, aucun step sans successeur) → rejet" do
      # Pour ce runtime séquentiel, « aucun terminal atteignable » == « cycle » :
      # une chaîne r → a → b → a n'a aucun step terminal. Rejetée comme :cycle.
      steps = %{"r" => step(), "a" => step(["r", "b"]), "b" => step(["a"])}
      assert {:error, {:cycle, _}} = GraphValidator.validate(steps)
    end
  end

  describe "atteignabilité" do
    test "composant orphelin (déconnecté de la racine) → :unreachable" do
      # r seul = chaîne principale ; x↔y forment un blob déconnecté (non atteignable
      # depuis r). Diagnostiqué :unreachable (câblage manquant) AVANT l'acyclicité.
      steps = %{
        "r" => step(),
        "x" => step(["y"]),
        "y" => step(["x"])
      }

      assert {:error, {:unreachable, %{steps: orphans}}} = GraphValidator.validate(steps)
      assert "x" in orphans and "y" in orphans
    end
  end

  describe "fan-out (branche parallèle, hors-scope séquentiel)" do
    test "un step avec ≥2 successeurs → :fan_out" do
      # a a deux successeurs (b et c) → branche parallèle, rejetée (runtime séquentiel).
      steps = %{
        "a" => step(),
        "b" => step(["a"]),
        "c" => step(["a"])
      }

      assert {:error, {:fan_out, %{step: "a", successors: ["b", "c"]}}} =
               GraphValidator.validate(steps)
    end
  end

  describe "describe/1 — message lisible par invariant" do
    test "phantom_edge nomme le step et le needs fautif" do
      msg = GraphValidator.describe({:phantom_edge, %{step: "build", needs: "foo"}})
      assert msg =~ "arête fantôme"
      assert msg =~ "build"
      assert msg =~ "foo"
    end
  end
end
