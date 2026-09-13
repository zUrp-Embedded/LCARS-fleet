defmodule Fleet.Pilot.ConflictReportTest do
  @moduledoc """
  Checks rendered trace summaries, outcome attribution and selected missing-data
  fallbacks. Rendering claims are tested as text, not proof of a push or jury rerun;
  these cases do not establish totality over malformed nested values.
  """
  use ExUnit.Case, async: true

  alias Fleet.Conflict.{ConfidenceScore, DecisionTrace, Hunk}
  alias Fleet.Pilot.ConflictReport

  defp hunk(opts \\ []) do
    %Hunk{
      base_lines: [],
      ours_lines: ["a"],
      theirs_lines: ["b"],
      start_line: Keyword.get(opts, :line, 1),
      type: Keyword.get(opts, :type, :complex),
      confidence: %ConfidenceScore{score: 10, label: Keyword.get(opts, :label, :low)},
      explanation: Keyword.get(opts, :explanation, ""),
      trace: %DecisionTrace{
        selected: Keyword.get(opts, :type, :complex),
        summary: Keyword.get(opts, :summary, ""),
        has_base: false
      },
      zdiff3: false
    }
  end

  defp diagnosis(hunks, totals \\ %{}) do
    %{
      files: %{"lib/a.ex" => %{hunks: hunks}},
      totals: Map.merge(%{total: length(hunks), trivial: 0, complex: 0, writable: 0}, totals)
    }
  end

  describe "what the report carries" do
    test "each hunk arrives with its line, its type, its confidence and the TRACE'S OWN sentence" do
      body =
        [
          hunk(
            line: 12,
            type: :complex,
            label: :low,
            summary: "aucun motif trivial ne s'applique"
          )
        ]
        |> diagnosis()
        |> ConflictReport.render(:all_semantic)

      assert body =~ "ligne 12"
      assert body =~ "`complex`"
      assert body =~ "confiance `low`"
      assert body =~ "aucun motif trivial ne s'applique"
    end

    test "the summary written by the classifier wins over the generic explanation" do
      body =
        [hunk(summary: "la base prouve que seul ours a changé", explanation: "générique")]
        |> diagnosis()
        |> ConflictReport.render(:auto_resolved)

      assert body =~ "la base prouve"
      refute body =~ "générique"
    end

    test "a hunk with NO recorded reason says so — an empty bullet reads as nothing to say" do
      body =
        [hunk(summary: "", explanation: "")]
        |> diagnosis()
        |> ConflictReport.render(:all_semantic)

      assert body =~ "aucune trace enregistrée"
      assert body =~ "anomalie du classifieur"
    end
  end

  describe "the two outcomes are the same evidence, one sentence apart" do
    test "an auto-resolution says the machine wrote AND that the jury re-judges the new head" do
      body =
        [hunk(type: :one_side_change)] |> diagnosis() |> ConflictReport.render(:auto_resolved)

      assert body =~ "résolu automatiquement"
      assert body =~ "juges re-jugent"

      assert body =~ "system_starfleet"
      assert body =~ "posté par le chief"
    end

    test "an all-semantic hand-off says nothing was written to the branch" do
      body = [hunk()] |> diagnosis() |> ConflictReport.render(:all_semantic)

      assert body =~ "rien n'est résoluble mécaniquement"
      assert body =~ "Aucune écriture n'a été faite"
      refute body =~ "résolu automatiquement"
    end
  end

  describe "it must never break the act it describes" do
    test "a diagnosis with only TOTALS renders a thinner report and NAMES what it lacks" do
      body = ConflictReport.render(%{totals: %{none_trivial?: true}}, :all_semantic)

      assert body =~ "pas de détail par fichier"
      assert body =~ "seuls les totaux"
    end

    test "a diagnosis of an unexpected shape does not raise — the report is best-effort" do
      assert is_binary(ConflictReport.render(%{}, :all_semantic))
      assert is_binary(ConflictReport.render(:not_a_map, :auto_resolved))
      assert is_binary(ConflictReport.render(nil, :auto_resolved))
    end

    test "a file report with no hunks is named, not silently skipped" do
      body =
        ConflictReport.render(%{files: %{"lib/x.ex" => %{}}, totals: %{}}, :all_semantic)

      assert body =~ "lib/x.ex"
      assert body =~ "rien à détailler"
    end
  end
end
