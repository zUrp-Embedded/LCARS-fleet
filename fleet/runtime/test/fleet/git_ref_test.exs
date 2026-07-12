defmodule Fleet.GitRefTest do
  @moduledoc """
  Verrouille l'AUTORITÉ unique de validation de ref git — primitive Ring 0 (`Fleet.Workflow.Git`,
  `Fleet.Workflow.Deliverable` et `Fleet.ProjectBootstrap.Phase.Clone` délèguent ici). Couvre les cas
  frontière du check-ref-format.
  """
  use ExUnit.Case, async: true

  alias Fleet.GitRef

  test "refs bien formées acceptées (slash, points, ref simple)" do
    for ok <- ["main", "feature/work", "lcars/issue-7-engineer", "release-1.2.3", "a"] do
      assert GitRef.valid?(ok), "ref #{inspect(ok)} devrait être valide"
    end
  end

  test "refs malformées rejetées (leading dash, espace, .., vide, non-binaire)" do
    for bad <- ["-force", "feat ure", "a..b", "..", "../evil", "", ".hidden", "/leading", nil, 42] do
      refute GitRef.valid?(bad), "ref #{inspect(bad)} devrait être rejetée"
    end
  end

  test "R2-06 : règles git check-ref-format qu'un regex de charset manque" do
    # trailing /, // (composant vide), trailing ., suffixe .lock, composant commençant par .
    for bad <- ["foo/", "a//b", "foo.", "foo.lock", "feature/foo.lock", "a/.hidden", "x/"] do
      refute GitRef.valid?(bad), "ref #{inspect(bad)} devrait être rejetée (git check-ref-format)"
    end

    # et les refs multi-composants légitimes restent acceptées
    for ok <- ["deliverables/engineer/m-42", "a/b/c", "release-1.2.3"] do
      assert GitRef.valid?(ok), "ref #{inspect(ok)} devrait rester valide"
    end
  end
end
