defmodule Fleet.ConflictTest do
  use ExUnit.Case, async: true

  alias Fleet.Conflict

  defp diff3(ours, base, theirs) do
    "<<<<<<< ours\n#{ours}\n||||||| base\n#{base}\n=======\n#{theirs}\n>>>>>>> theirs"
  end

  describe "trivial resolution (diff3)" do
    test "same_change: both sides made the same edit" do
      {:ok, r} = Conflict.resolve(diff3("b", "a", "b"))
      assert r.merged == "b"
      assert [%{type: :same_change}] = r.hunks
      assert r.stats == %{trivial: 1, complex: 0, total: 1, writable: 1}
    end

    test "one_side_change: only theirs changed -> accept theirs" do
      {:ok, r} = Conflict.resolve(diff3("a", "a", "b"))
      assert r.merged == "b"
      assert [%{type: :one_side_change}] = r.hunks
    end

    test "one_side_change: only ours changed -> accept ours" do
      {:ok, r} = Conflict.resolve(diff3("b", "a", "a"))
      assert r.merged == "b"
    end

    test "delete_no_change: ours deleted, theirs untouched -> delete" do
      content = "<<<<<<< ours\n||||||| base\na\n=======\na\n>>>>>>> theirs"
      {:ok, r} = Conflict.resolve(content)
      assert r.merged == ""
      assert [%{type: :delete_no_change}] = r.hunks
    end
  end

  describe "complex -> unresolved, markers restored" do
    test "both sides changed differently" do
      {:ok, r} = Conflict.resolve(diff3("b", "a", "c"))
      assert r.merged == nil
      assert [%{type: :complex}] = r.hunks
      assert r.stats.complex == 1
    end
  end

  # DEUX GARANTIES « NEVER GUESSES » QUE RIEN NE TENAIT. Mesure du 2026-08-08, chaque mutation
  # contre la suite entiere (2441 tests) : faire GARDER les lignes a `:delete_no_change` au lieu de
  # supprimer, et faire DEVINER `:non_overlapping` quand le merge 3-way rend `nil`, laissaient tout
  # vert. Ce module decide quel code survit a un merge : un regresseur qui devine au lieu de passer
  # la main merge du code faux, en silence, et le `@moduledoc` promet exactement l'inverse.
  #
  # (Un troisieme repli — la clause fourre-tout `resolve_lines(%Hunk{})` — a survecu lui aussi a sa
  # mutation, mais il est INATTEIGNABLE par conception : `:complex` n'est pas dans
  # `@writable_types`, donc `try_resolve/2` ne l'appelle jamais. C'est un filet pour un type
  # writable qui serait ajoute sans clause. Pas un defaut, et pas de test invente pour lui.)
  describe "never guesses" do
    test "delete_no_change SUPPRIME le bloc — garder les lignes serait ressusciter du code efface" do
      # C'est THEIRS qui supprime, pas ours — et ce detail EST le test. Avec le cote vide du cote
      # `ours`, la mutation « rendre `h.ours_lines` au lieu de `[]` » rend `[]` elle aussi : le
      # fixture ne distingue pas les deux mondes et passe dans les deux sens. Mesure faite : premiere
      # version du test, mutation appliquee, 2443 verts. Ici `ours_lines == ["a"]`, donc garder
      # ressusciterait la ligne effacee et le merge le montre.
      content = "top\n<<<<<<< ours\na\n||||||| base\na\n=======\n>>>>>>> theirs\nbottom"

      {:ok, r} = Conflict.resolve(content)

      assert [%{type: :delete_no_change}] = r.hunks
      assert r.merged == "top\nbottom", "le bloc supprime d'un cote doit disparaitre du merge"
    end

    test "non_overlapping dont le merge 3-way ECHOUE passe la main, il n'invente pas" do
      # Teste `Assemble.resolve_lines/1` en direct : produire ce hunk par le classifieur
      # demanderait un texte qui se classe `non_overlapping` ET dont le LCS echoue — l'assembleur
      # est la surface publique ou la decision se prend, et c'est elle qui doit tenir.
      h = %Fleet.Conflict.Hunk{
        base_lines: ["a"],
        ours_lines: ["b"],
        theirs_lines: ["c"],
        start_line: 1,
        type: :non_overlapping,
        confidence: %Fleet.Conflict.ConfidenceScore{score: 90, label: :high},
        explanation: "fixture",
        trace: %Fleet.Conflict.DecisionTrace{
          selected: :non_overlapping,
          summary: "fixture",
          has_base: true
        }
      }

      # Le merge 3-way ne sait pas combiner ces trois cotes — verifie, pas suppose.
      assert Fleet.Conflict.Diff.merge_non_overlapping(["a"], ["b"], ["c"]) == nil

      assert Fleet.Conflict.Assemble.resolve_lines(h) == :skip,
             "un 3-way qui echoue doit rendre :skip (marqueurs restaures, routage amont), " <>
               "jamais un cote choisi au hasard"
    end
  end

  describe "surrounding text is preserved" do
    test "leading and trailing text kept around a resolved hunk" do
      content = "top\n" <> diff3("b", "a", "b") <> "\nbottom"
      {:ok, r} = Conflict.resolve(content)
      assert r.merged == "top\nb\nbottom"
    end
  end

  describe "decision trace" do
    test "records the selected type, the base flag, and the passing step" do
      {:ok, r} = Conflict.resolve(diff3("a", "a", "b"))
      [h] = r.hunks
      assert h.trace.selected == :one_side_change
      assert h.trace.has_base
      assert Enum.any?(h.trace.steps, &(&1.type == :one_side_change and &1.passed))
    end
  end

  describe "CRLF separator (ported scar)" do
    test "a CRLF conflict still parses into three sections" do
      content =
        "<<<<<<< ours\r\nb\r\n||||||| base\r\na\r\n=======\r\nb\r\n>>>>>>> theirs\r"

      {:ok, r} = Conflict.resolve(content)

      # ours and theirs are both "b\r" -> same_change (the separator "=======\r" must be recognized)
      assert [%{type: :same_change}] = r.hunks
    end
  end

  describe "diff2 (no base) is conservative" do
    test "a diff2 deletion is only medium confidence -> not auto-resolved at :high" do
      content = "<<<<<<< ours\n=======\na\n>>>>>>> theirs"
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :delete_no_change, confidence: %{label: :medium}}] = r.hunks
      assert r.merged == nil
    end
  end
end
