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
      # Python/YAML indentation can change semantics even when classification scores :high.
      content = diff3("a", "  a", "    a")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :whitespace_only, confidence: %{label: :high}}] = r.hunks
      refute r.merged, "a whitespace assumption must never reach the worktree"
      assert r.stats == %{trivial: 1, complex: 0, total: 1, writable: 0}
    end

    test "whitespace inside a string is data -> not whitespace_only" do
      # This fixture also matches one_side_change first (theirs == base); it does not
      # isolate the whitespace detector's handling of quoted strings.
      content = diff3(~s|x = "a  b"|, ~s|x = "a b"|, ~s|x = "a b"|)
      {:ok, r} = Conflict.resolve(content)
      refute match?([%{type: :whitespace_only}], r.hunks)
    end
  end

  describe "reorder_only" do
    test "same lines, different order (diff2) -> CLASSIFIED, never auto-written" do
      # Order affects Docker commands, CSS precedence and auth/log sequencing.
      content = diff2("a\nb", "b\na")
      {:ok, r} = Conflict.resolve(content)
      assert [%{type: :reorder_only}] = r.hunks
      refute r.merged, "an order assumption must never reach the worktree"
    end
  end

  describe "insertion_at_boundary" do
    test "both sides insert at the same boundary -> CLASSIFIED, never auto-written" do
      # A union can duplicate alternative YAML keys, definitions or CSS properties.
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
      # Both the default floor and the writable-type gate refuse this candidate.
      assert r.merged == nil
    end

    test "lowering the floor to :medium does NOT unlock it — the type gate is independent" do
      # Lowering the floor cannot authorize a type whose assembler may default to theirs.
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

  # Le budget borne les cellules DP pendant la classification, pas la mémoire totale ni le temps.
  describe "JG-050 — le budget LCS borne la table" do
    defp lines(n), do: for(i <- 1..n, do: "ligne #{i}")

    test "la frontiere est exacte, et elle se lit en O(1) sur les longueurs" do
      # Le prédicat traverse les listes pour calculer leurs longueurs ; ce test ne mesure pas le coût.
      cap = Diff.max_lcs_cells()
      refute Diff.over_lcs_budget?(lines(1), lines(cap))
      assert Diff.over_lcs_budget?(lines(1), lines(cap + 1))
    end

    test "au-dela, `lcs/2` REFUSE au lieu de rendre une liste vide" do
      # [] signifierait « aucune ligne commune », alors que la comparaison a été refusée.
      over = Diff.max_lcs_cells() + 1
      assert Diff.lcs(lines(1), lines(over)) == {:error, :too_large}

      assert Diff.merge_non_overlapping(lines(1), lines(over), lines(over)) ==
               {:error, :too_large}
    end

    test "TEMOIN — sous le budget, la fusion se fait normalement" do
      # Témoin contre un LCS qui refuserait toutes les entrées.
      assert {:ok, ["X", "a", "b", "Y"]} =
               Diff.merge_non_overlapping(["a", "b"], ["X", "a", "b"], ["a", "b", "Y"])
    end

    test "un hunk hors budget est DECLINE, et la trace ne lui invente pas un chevauchement" do
      big = Enum.map_join(1..600, "\n", &"ligne #{&1}")
      ours = "OURS\n" <> big
      theirs = big <> "\nTHEIRS"
      content = "<<<<<<< ours\n#{ours}\n||||||| base\n#{big}\n=======\n#{theirs}\n>>>>>>> theirs"

      {:ok, r} = Conflict.resolve(content)

      assert [%{type: type, trace: trace}] = r.hunks

      refute type == :non_overlapping,
             "hors budget, aucun merge n'a eu lieu : rien a classer ainsi"

      step = Enum.find(trace.steps, &(&1.type == :non_overlapping))

      assert step.reason =~ "too large",
             "la trace disait « both branches touched the same lines » d'un bloc jamais compare — " <>
               "un refus qui invente son motif est pire qu'un refus"
    end
  end

  # La trace mesure les appels réels, sans ajouter de compteur au code de fusion.
  describe "JG-051 — la fusion trois voies n'est calculee qu'une fois par hunk" do
    # Tracer un autre processus : le traceur lui-même est exclu et ne produirait aucun appel.
    defp count_merges(fun) do
      {pid, ref} =
        spawn_monitor(fn ->
          receive do
            :go -> fun.()
          end
        end)

      # alias ne charge pas le module ; sinon trace_pattern peut armer zéro fonction.
      Code.ensure_loaded!(Diff)

      :erlang.trace(pid, true, [:call])

      assert :erlang.trace_pattern({Diff, :merge_non_overlapping, 3}, true, [:local]) == 1,
             "le motif de trace n'a arme aucune fonction — la mesure qui suit serait vide"

      send(pid, :go)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000
      :erlang.trace_pattern({Diff, :merge_non_overlapping, 3}, false, [:local])
      drain_traces(0)
    end

    # :DOWN et traces peuvent arriver dans un ordre différent. Attendre jusqu'à 200 ms tant
    # qu'aucun appel n'a été compté, puis drainer sans délai ; cela ne prouve pas qu'aucune
    # trace supplémentaire ne reste en vol.
    defp drain_traces(n) do
      receive do
        {:trace, _pid, :call, {Diff, :merge_non_overlapping, _}} -> drain_traces(n + 1)
        {:trace, _pid, _, _} -> drain_traces(n)
      after
        wait_for_traces(n) -> n
      end
    end

    defp wait_for_traces(0), do: 200
    defp wait_for_traces(_), do: 0

    test "un hunk non-overlapping resolu ne fusionne qu'une fois" do
      content = "<<<<<<< ours\nX\na\nb\n||||||| base\na\nb\n=======\na\nb\nY\n>>>>>>> theirs"

      calls = count_merges(fn -> {:ok, _} = Conflict.resolve(content) end)

      assert calls == 1, "la fusion a tourne #{calls} fois pour un seul hunk"
    end

    test "TEMOIN — l'instrument compte bien, il ne rend pas 1 par construction" do
      # Témoin à deux appels contre un compteur constant ou une trace non armée.
      calls =
        count_merges(fn ->
          Diff.merge_non_overlapping(["a"], ["b"], ["c"])
          Diff.merge_non_overlapping(["a"], ["b"], ["c"])
        end)

      assert calls == 2
    end

    test "un hunk regle par un motif PRIORITAIRE ne paie jamais la fusion" do
      # same_change gagne avant que la fusion soit tentée.
      calls =
        count_merges(fn -> {:ok, _} = Conflict.resolve(diff3("b", "a", "b")) end)

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
