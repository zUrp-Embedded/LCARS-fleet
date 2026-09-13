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

  describe "complex -> unresolved, nothing written" do
    test "both sides changed differently" do
      {:ok, r} = Conflict.resolve(diff3("b", "a", "c"))
      assert r.merged == nil
      assert [%{type: :complex}] = r.hunks
      assert r.stats.complex == 1
    end
  end

  # EOF dans un conflit doit être une erreur : seul, il ressemblait à un fichier propre ;
  # après un hunk résolu, il permettait un candidat amputé. Ces tests n'écrivent pas sur disque.
  describe "conflit non referme -> erreur structuree, jamais un rapport de fichier propre" do
    @states [
      {:ours, "<<<<<<< ours\nperdu\n"},
      {:base, "<<<<<<< ours\na\n||||||| base\nperdu\n"},
      {:theirs, "<<<<<<< ours\na\n||||||| base\nb\n=======\nperdu\n"}
    ]

    for {state, content} <- @states do
      test "EOF dans l'etat #{state}, seul" do
        assert {:error, {:unterminated_conflict, unquote(state), 1}} =
                 Conflict.resolve(unquote(content))
      end

      test "EOF dans l'etat #{state}, APRES un hunk resolvable — c'est le cas qui ecrivait" do
        prefix = diff3("b", "a", "b") <> "\ntail\n"
        content = prefix <> unquote(content)

        # Témoin : sans le conflit orphelin, ce préfixe produit bien un candidat.
        assert {:ok, %{merged: "b\ntail\n", stats: %{writable: 1}}} = Conflict.resolve(prefix)

        # L'erreur doit viser l'ouverture orpheline en 9, pas le premier conflit en 1.
        assert {:error, {:unterminated_conflict, unquote(state), 9}} = Conflict.resolve(content)
      end
    end

    test "TEMOIN — le meme contenu, marqueur referme, se resout normalement" do
      # Distingue la garde d'un parseur qui refuserait tous les conflits.
      assert {:ok, %{merged: "b"}} = Conflict.resolve(diff3("b", "a", "b"))
      assert {:ok, %{merged: nil, stats: %{total: 1}}} = Conflict.resolve(diff3("b", "a", "c"))
    end

    test "un fichier PROPRE et un conflit non referme ne rendent plus la meme chose" do
      assert {:ok, %{merged: nil, hunks: [], stats: %{total: 0}}} =
               Conflict.resolve("aucun conflit ici\n")

      assert {:error, _} = Conflict.resolve("<<<<<<< ours\nrien ne referme\n")
    end
  end

  # Régressions ciblées de l'assemblage. Le titre historique ne couvre pas les autres heuristiques
  # appelables directement. La clause fourre-tout protège un futur type sans assembleur ;
  # :complex n'y arrive pas depuis Conflict.resolve/2, qui l'exclut avant l'appel.
  describe "never guesses" do
    test "delete_no_change SUPPRIME le bloc — garder les lignes serait ressusciter du code efface" do
      # Theirs supprime : retourner ours_lines au lieu de [] doit échouer. Un ours vide
      # masquerait cette mutation et laisserait le test vert.
      content = "top\n<<<<<<< ours\na\n||||||| base\na\n=======\n>>>>>>> theirs\nbottom"

      {:ok, r} = Conflict.resolve(content)

      assert [%{type: :delete_no_change}] = r.hunks
      assert r.merged == "top\nbottom", "le bloc supprime d'un cote doit disparaitre du merge"
    end

    test "non_overlapping dont le merge 3-way ECHOUE passe la main, il n'invente pas" do
      # Hunk manuel : le classifieur ne choisit non_overlapping qu'après une fusion réussie.
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

      # Sans merged_lines, l'assembleur recalcule. Témoin d'un chevauchement réel, pas d'un
      # dépassement du budget. :skip ne restaure pas de marqueurs malgré le message historique.
      assert Fleet.Conflict.Diff.merge_non_overlapping(["a"], ["b"], ["c"]) == {:error, :overlap}

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
