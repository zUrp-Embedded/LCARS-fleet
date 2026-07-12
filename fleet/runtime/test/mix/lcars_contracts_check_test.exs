defmodule Mix.Tasks.Lcars.Contracts.CheckTest do
  @moduledoc """
  Smoke/regression du gate `mix lcars.contracts.check` : `run_checks/0` tourne contre le VRAI umbrella
  et doit passer, tous les checks verts. Verrouille que les gardes anti-hollow-green (R0-EVT-012/014 :
  residue-target absente = fail, events.yaml absent = fail, seam malformé = fail) n'ont pas introduit de
  faux-rouge, et qu'une régression future d'un contrat casse ce test.

  NB : tester les CHEMINS fail-on-absent directement (fixture sans events.yaml, seam malformé) demanderait
  un `run_checks(root)` root-injectable — refactor de test-infra séparé, non fait ici.
  """
  use ExUnit.Case, async: true

  test "run_checks passe sur le vrai repo + tous les checks verts (gardes hollow-green sans faux-rouge)" do
    assert {:pass, checks} = Mix.Tasks.Lcars.Contracts.Check.run_checks()

    ids = Enum.map(checks, & &1.id)
    # les deux checks durcis R0-EVT-012/014 tournent
    assert "events.handlers.exist" in ids
    assert "layering.dependency_graph" in ids

    fails = Enum.filter(checks, &(&1.status != :pass))
    assert fails == [], "checks non-verts : #{inspect(Enum.map(fails, &{&1.id, &1.evidence}))}"
  end
end
