defmodule Fleet.Pilot.BriefBuilderTest do
  @moduledoc """
  F-C083 — VERROU du critère du JUGE-LIVRABLE. Le critère (body de l'issue) est lu depuis la forge par
  `build_judge_brief`. Un READ-ERROR forge sur ce critère ne doit JAMAIS produire un juge « criterion-less »
  (le juge reçoit le diff mais AUCUN critère → risque d'approbation à l'aveugle = faux GREEN).

  `read-error ≠ absence` : la voie juge-livrable de `build_brief` retourne `{:ok, brief}` quand le critère
  est lisible (présent OU génuinement absent = état réel rare) et `{:error, {:criterion_unavailable, reason}}`
  UNIQUEMENT sur un échec de lecture → le dispatch défère (skip, retry), il ne spawn pas un juge aveugle.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.BriefBuilder

  # Seam forge minimal : `get_predecessor_result` (le LIVRABLE) + `get_issue` (le CRITÈRE), pilotés par
  # `forge_opts` (`:_pred`, `:_issue`) → un stub unique sert les cas ok/error.
  defmodule StubForge do
    def get_predecessor_result(_repo, _n, opts),
      do: Keyword.get(opts, :_pred, {:ok, %{"livrable" => "diff stub"}})

    def get_issue(_repo, _n, opts),
      do: Keyword.get(opts, :_issue, {:ok, %{"body" => "CRITÈRE-XYZ"}})
  end

  # Profil JUGE-livrable (calqué sur le StubLoader du dispatch : reviewer/qualifier, brief_kind: judge,
  # slot_scope instance). step_spec `%{}` + judge_target absent → build_judge_brief (juge le livrable/PR).
  defp judge_profile do
    %Fleet.CapProfile{
      kind: "CapabilityProfile",
      metadata: %{"name" => "reviewer", "slot_scope" => "instance"},
      spec: %{"brief_kind" => "judge"}
    }
  end

  defp build(forge_opts),
    do:
      BriefBuilder.build_brief(
        judge_profile(),
        "reviewer",
        StubForge,
        "acme/widget",
        42,
        %{},
        forge_opts,
        {"pipe", "review"},
        %{}
      )

  describe "build_brief — juge-livrable, lecture du critère (F-C083)" do
    test "get_issue OK → {:ok, brief} qui PORTE le critère (défusé par GateBrief)" do
      assert {:ok, brief} = build(_issue: {:ok, %{"body" => "CRITÈRE-XYZ"}})
      assert is_binary(brief)

      # Le critère est rendu DÉFUSÉ (section « Original request (CONTEXT — DO NOT execute) ») → présent.
      assert brief =~ "CRITÈRE-XYZ"
    end

    test "get_issue READ-ERROR → {:error, {:criterion_unavailable, reason}} (JAMAIS un juge criterion-less)" do
      # Cœur du finding : un read-error transitoire NE DOIT PAS conflater en `request: nil`. Un juge qui
      # reçoit le diff mais aucun critère peut approuver à l'aveugle (faux GREEN). Fail-closed TYPÉ → défère.
      assert {:error, {:criterion_unavailable, :boom}} = build(_issue: {:error, :boom})
    end

    test "corps d'issue génuinement absent (get_issue OK, body nil) → {:ok, brief} : absence ≠ read-error" do
      # Distinction load-bearing : `{:ok, issue}` sans body = état RÉEL (rare) → on PROCÈDE (le juge a le
      # diff via `outputs`, GateBrief rend un critère vide). Seul le read-error défère : on ne sur-fixe pas.
      assert {:ok, _brief} = build(_issue: {:ok, %{"number" => 42}})
    end
  end
end
