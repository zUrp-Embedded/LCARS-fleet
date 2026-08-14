defmodule Fleet.Conflict.PatternsTest do
  use ExUnit.Case, async: true

  alias Fleet.Conflict
  alias Fleet.Conflict.{Diff, Patterns.Utils}

  defp diff3(ours, base, theirs) do
    "<<<<<<< ours\n#{ours}\n||||||| base\n#{base}\n=======\n#{theirs}\n>>>>>>> theirs"
  end

  defp diff2(ours, theirs) do
    "<<<<<<< ours\n#{ours}\n=======\n#{theirs}\n>>>>>>> theirs"
  end

  describe "non_overlapping" do
    test "disjoint insertions merge via 3-way LCS" do
      content = diff3("a\nX\nb\nc", "a\nb\nc", "a\nb\nc\nY")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :non_overlapping}] = r.hunks
      assert r.merged == "a\nX\nb\nc\nY"
    end
  end

  describe "whitespace_only" do
    test "same code, different indentation -> CLASSIFIED, never auto-written" do
      # Classification is real and useful (it routes the tier: this is shallow). Writing it is not
      # ours to do: the engine is format-blind, and in Python an indent/dedent changes scope, in
      # YAML it changes which key owns the value. Measured on the deployed build before this gate:
      # `    return a` vs `\treturn a` resolved at :high and rewrote the block.
      content = diff3("a", "  a", "    a")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :whitespace_only, confidence: %{label: :high}}] = r.hunks
      refute r.merged, "a whitespace assumption must never reach the worktree"
      assert r.stats == %{trivial: 1, complex: 0, total: 1, writable: 0}
    end

    test "whitespace inside a string is data -> not whitespace_only" do
      # ours and theirs normalize equal on layout but the quoted content differs
      content = diff3(~s|x = "a  b"|, ~s|x = "a b"|, ~s|x = "a b"|)
      {:ok, r} = Conflict.resolve(content)
      refute match?([%{type: :whitespace_only}], r.hunks)
    end
  end

  describe "reorder_only" do
    test "same lines, different order (diff2) -> CLASSIFIED, never auto-written" do
      # Order carries meaning far too often to guess: `RUN apt update` after `apt install`, CSS
      # last-declaration-wins, and `log()` before `auth()` -- the engine reordered an auth check
      # ahead of its log at :high before this gate.
      content = diff2("a\nb", "b\na")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :reorder_only}] = r.hunks
      refute r.merged, "an order assumption must never reach the worktree"
    end
  end

  describe "insertion_at_boundary" do
    test "both sides insert at the same boundary -> CLASSIFIED, never auto-written" do
      # The union is right when the two insertions are ADDITIVE and wrong when they are
      # ALTERNATIVES -- and nothing in the text says which. Measured before this gate: two sides
      # setting the same key produced `timeout: 30` AND `timeout: 60` (invalid in strict YAML), two
      # sides defining `def run` kept both (dead clause), two sides setting `color:` kept both (ours
      # silently lost to CSS last-wins).
      content = diff3("a\nX", "a", "a\nY")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :insertion_at_boundary}] = r.hunks
      refute r.merged, "keeping both insertions must never reach the worktree unreviewed"
    end
  end

  describe "value_only_change" do
    test "both changed only a version -> classified value_only, medium at 20% ratio" do
      content = diff3("version = 1.2.0", "version = 1.0.0", "version = 1.1.0")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :value_only_change, confidence: %{label: :medium}}] = r.hunks
      # medium -> not auto-resolved at the default :high floor
      assert r.merged == nil
    end

    test "lowering the floor to :medium does NOT unlock it — the type gate is independent" do
      # The confidence floor and the write gate answer different questions. Lowering the floor used
      # to hand the disk to a value pick; it no longer can, because `value_only_change` is not an
      # auto-writable type at ANY floor. The reason is measured, not theoretical: for an unorderable
      # volatile `Assemble` itself records "not orderable -- accept theirs (default)", i.e. a coin
      # flip. A sha `aaaa1111` vs `bbbb2222` resolved to theirs at :high before this gate.
      content = diff3("version = 1.2.0", "version = 1.0.0", "version = 1.1.0")
      {:ok, r} = Conflict.resolve(content, min_confidence: :medium)
      assert [%{type: :value_only_change}] = r.hunks
      refute r.merged
    end

    test "an UNORDERABLE volatile is where the pick is a coin flip (the reason for the gate)" do
      content = diff3(~s|sha = "aaaa1111"|, ~s|sha = "0000abcd"|, ~s|sha = "bbbb2222"|)
      {:ok, r} = Conflict.resolve(content, min_confidence: :low)
      assert [%{type: :value_only_change}] = r.hunks
      refute r.merged, "no ordering exists between two hashes; picking one is not a resolution"
    end
  end

  describe "unit: Diff.merge_non_overlapping" do
    test "overlapping edits -> {:error, :overlap}" do
      assert Diff.merge_non_overlapping(["a"], ["b"], ["c"]) == {:error, :overlap}
    end

    test "disjoint edits -> merged" do
      assert Diff.merge_non_overlapping(["a", "b"], ["X", "a", "b"], ["a", "b", "Y"]) ==
               {:ok, ["X", "a", "b", "Y"]}
    end
  end

  # JG-050 — LA TABLE EST LE COUT, ET RIEN NE LA BORNAIT. `lcs/2` remplit une entree de map
  # persistante par couple `{i, j}`. Mesure sur ce build : 250 000 cellules coutent 21 Mio et
  # 179 ms, soit ~91 octets et ~0.71 us la cellule, en quadratique. Un hunk de 5 000 lignes de
  # chaque cote — un lockfile, un fichier genere, un instantane, c'est-a-dire EXACTEMENT ce qui
  # produit les gros conflits — fait 25 millions de cellules : ~2.2 Gio et ~18 s pour UNE table, et
  # une fusion trois voies en construit DEUX. Le calcul a lieu pendant la CLASSIFICATION, avant
  # toute decision de resoudre.
  describe "JG-050 — le budget LCS borne la table" do
    defp lines(n), do: for(i <- 1..n, do: "ligne #{i}")

    test "la frontiere est exacte, et elle se lit en O(1) sur les longueurs" do
      cap = Diff.max_lcs_cells()
      refute Diff.over_lcs_budget?(lines(1), lines(cap))
      assert Diff.over_lcs_budget?(lines(1), lines(cap + 1))
    end

    test "au-dela, `lcs/2` REFUSE au lieu de rendre une liste vide" do
      # Une liste vide serait le pire retour possible : « ces sequences n'ont rien en commun » est
      # une reponse plausible, indistinguable d'un refus, et elle ferait produire un diff FAUX avec
      # confiance. Le refus est explicite pour que personne ne puisse le lire comme un resultat.
      over = Diff.max_lcs_cells() + 1
      assert Diff.lcs(lines(1), lines(over)) == {:error, :too_large}

      assert Diff.merge_non_overlapping(lines(1), lines(over), lines(over)) ==
               {:error, :too_large}
    end

    test "TEMOIN — sous le budget, la fusion se fait normalement" do
      # La borne doit se prouver sur ce qu'elle LAISSE PASSER : sans ce temoin, un `lcs/2` qui
      # refuserait tout passerait les deux tests ci-dessus.
      assert {:ok, ["X", "a", "b", "Y"]} =
               Diff.merge_non_overlapping(["a", "b"], ["X", "a", "b"], ["a", "b", "Y"])
    end

    test "un hunk hors budget est DECLINE, et la trace ne lui invente pas un chevauchement" do
      big = Enum.map_join(1..600, "\n", &"ligne #{&1}")
      ours = "OURS\n" <> big
      theirs = big <> "\nTHEIRS"
      content = "<<<<<<< ours\n#{ours}\n||||||| base\n#{big}\n=======\n#{theirs}\n>>>>>>> theirs"

      {:ok, r} = Fleet.Conflict.resolve(content)

      assert [%{type: type, trace: trace}] = r.hunks

      refute type == :non_overlapping,
             "hors budget, aucun merge n'a eu lieu : rien a classer ainsi"

      step = Enum.find(trace.steps, &(&1.type == :non_overlapping))

      assert step.reason =~ "too large",
             "la trace disait « both branches touched the same lines » d'un bloc jamais compare — " <>
               "un refus qui invente son motif est pire qu'un refus"
    end
  end

  # JG-051 — `NonOverlapping.detect?/1` REPOND EN FUSIONNANT, et l'assembleur redemandait la meme
  # fusion : le calcul le plus cher du sous-systeme tournait deux fois par hunk, le premier resultat
  # jete. Compte par `:erlang.trace/3` — la fonction n'a pas de couture, et un compteur pose dans le
  # code mesurerait le compteur.
  describe "JG-051 — la fusion trois voies n'est calculee qu'une fois par hunk" do
    # ⚠ LE TRAVAIL TOURNE DANS UN AUTRE PROCESSUS, ET CE N'EST PAS DU CONFORT : le processus
    # TRACEUR est exclu du tracage. Tracer `self()` depuis `self()` rend `trace/3 -> 1` et
    # `trace_pattern -> 1` — deux retours qui disent « arme » — puis ZERO message. Un instrument qui
    # repond « rien » a l'identique d'un sujet qui ne fait rien.
    defp count_merges(fun) do
      {pid, ref} =
        spawn_monitor(fn ->
          receive do
            :go -> fun.()
          end
        end)

      :erlang.trace(pid, true, [:call])
      :erlang.trace_pattern({Diff, :merge_non_overlapping, 3}, true, [:local])
      send(pid, :go)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000
      :erlang.trace_pattern({Diff, :merge_non_overlapping, 3}, false, [:local])
      drain_traces(0)
    end

    defp drain_traces(n) do
      receive do
        {:trace, _pid, :call, {Diff, :merge_non_overlapping, _}} -> drain_traces(n + 1)
        {:trace, _pid, _, _} -> drain_traces(n)
      after
        0 -> n
      end
    end

    test "un hunk non-overlapping resolu ne fusionne qu'une fois" do
      content = "<<<<<<< ours\nX\na\nb\n||||||| base\na\nb\n=======\na\nb\nY\n>>>>>>> theirs"

      calls = count_merges(fn -> {:ok, _} = Fleet.Conflict.resolve(content) end)

      assert calls == 1, "la fusion a tourne #{calls} fois pour un seul hunk"
    end

    test "TEMOIN — l'instrument compte bien, il ne rend pas 1 par construction" do
      # Sans ce temoin, un `:erlang.trace` mal arme rendrait 1 (ou 0) quoi qu'il arrive, et le test
      # ci-dessus serait vert sur une mesure morte.
      calls =
        count_merges(fn ->
          Diff.merge_non_overlapping(["a"], ["b"], ["c"])
          Diff.merge_non_overlapping(["a"], ["b"], ["c"])
        end)

      assert calls == 2
    end

    test "un hunk regle par un motif PRIORITAIRE ne paie jamais la fusion" do
      # La capture reste PARESSEUSE : `same_change` gagne avant que `non_overlapping` soit atteint.
      calls =
        count_merges(fn -> {:ok, _} = Fleet.Conflict.resolve(diff3("b", "a", "b")) end)

      assert calls == 0
    end
  end

  describe "unit: Utils.pick_newer_side" do
    test "higher semver wins, same side across the block" do
      assert Utils.pick_newer_side(["v = 1.2.0"], ["v = 1.1.0"]) == :ours
      assert Utils.pick_newer_side(["v = 1.1.0"], ["v = 2.0.0"]) == :theirs
    end

    test "disagreeing sides -> nil (fall back to policy)" do
      assert Utils.pick_newer_side(["a = 2.0.0", "b = 1.0.0"], ["a = 1.0.0", "b = 2.0.0"]) == nil
    end

    test "non-orderable values -> nil" do
      assert Utils.pick_newer_side(["h = abcdef1"], ["h = 9876543"]) == nil
    end
  end
end
