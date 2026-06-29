defmodule Fleet.Pipeline.GitRefTest do
  @moduledoc """
  Verrouille l'AUTORITÉ unique de validation de ref git (`Fleet.Pipeline.Git` et
  `Fleet.Pipeline.Deliverable` délèguent ici). Couvre les cas frontière du check-ref-format.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pipeline.GitRef

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
end
