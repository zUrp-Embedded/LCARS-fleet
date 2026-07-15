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
    # MIGRATION Z3 (D-19) : layering.dependency_graph est RETIRÉ avec sa matière première
    # (edges in_umbrella des mix.exs d'apps) — successeur mécanique = boundary (Z4).
    # Son remplaçant vérifiable aujourd'hui : boot.order_f8 (ordre des children racine).
    assert "boot.order_f8" in ids

    fails = Enum.filter(checks, &(&1.status != :pass))
    assert fails == [], "checks non-verts : #{inspect(Enum.map(fails, &{&1.id, &1.evidence}))}"
  end

  describe "code_match?/4 — anti-hollow-green : un marqueur en PROSE ne compte pas (BND-111)" do
    @tag :tmp_dir
    test "un marqueur présent SEULEMENT dans un @moduledoc/@doc → false (pas de faux-vert)", %{
      tmp_dir: tmp
    } do
      # Le piège BND-111 : la doc de valeur-de-retour NOMME le tuple `{:error, :brief_required}` ; si le
      # check greppe le tuple sans exclure les blocs @doc, une régression du guard EXÉCUTABLE resterait
      # verte tant que la doc reste. On prouve ici que le tuple en prose SEULE ne satisfait PAS le check.
      File.write!(Path.join(tmp, "prose_only.ex"), """
      defmodule ProseOnly do
        @moduledoc \"\"\"
        Returns:
          * `{:error, :brief_required}` — one-shot pod without a brief
        \"\"\"

        @doc \"\"\"
        Otherwise `{:error, :brief_required}`.
        \"\"\"
        def spawn_pod(_), do: :ok
      end
      """)

      refute Mix.Tasks.Lcars.Contracts.Check.code_match?(tmp, "prose_only.ex", ~r/:brief_required/, [
               ~r/:brief_required/,
               ~r/^\s*\{:error, :brief_required\}/
             ]),
             "un tuple présent uniquement dans @moduledoc/@doc ne doit PAS compter comme code"
    end

    @tag :tmp_dir
    test "le MÊME marqueur sur une ligne EXÉCUTABLE → true (le guard réel compte)", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "real_guard.ex"), """
      defmodule RealGuard.Doc do
        @moduledoc \"\"\"
        Returns `{:error, :brief_required}` in prose here.
        \"\"\"
      end

      defmodule RealGuard do
        def spawn_pod(opts) do
          if opts[:brief], do: :ok, else: {:error, :brief_required}
        end
      end
      """)

      assert Mix.Tasks.Lcars.Contracts.Check.code_match?(tmp, "real_guard.ex", ~r/:brief_required/, [
               ~r/:brief_required/,
               ~r/^\s*.*\{:error, :brief_required\}/
             ]),
             "le tuple sur la ligne exécutable du guard doit compter"
    end
  end
end
