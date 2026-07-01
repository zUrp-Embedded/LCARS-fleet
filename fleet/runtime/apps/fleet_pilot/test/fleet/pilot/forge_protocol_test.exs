defmodule Fleet.Pilot.ForgeProtocolTest do
  use ExUnit.Case, async: true

  # Vocabulaire PUR du wire-protocol (aucun I/O) : build+parse co-localisés. Chaque describe prouve
  # l'invariant `parse ∘ build == identité` (un changement de format casse le test ici, pas en prod).
  alias Fleet.Pilot.ForgeProtocol

  describe "feature_branch/2 + parse_feature_branch/1 (build+parse co-localisés)" do
    test "parse_feature_branch extrait {issue, role} d'une branche systeme" do
      assert {:ok, {42, "engineer"}} =
               ForgeProtocol.parse_feature_branch("lcars/issue-42-engineer")

      assert {:ok, {7, "reviewer"}} = ForgeProtocol.parse_feature_branch("lcars/issue-7-reviewer")
    end

    test "parse_feature_branch :error sur une branche non-fleet" do
      assert :error = ForgeProtocol.parse_feature_branch("refs/pull/55/head")
      assert :error = ForgeProtocol.parse_feature_branch("main")
      assert :error = ForgeProtocol.parse_feature_branch("feature/manual")
      assert :error = ForgeProtocol.parse_feature_branch(nil)
    end

    test "feature_branch/2 construit le format ET parse∘build == identité" do
      assert "lcars/issue-42-engineer" = ForgeProtocol.feature_branch(42, "engineer")

      for {n, role} <- [{1, "engineer"}, {12, "reviewer"}, {999, "qualifier"}] do
        assert {:ok, {^n, ^role}} =
                 ForgeProtocol.parse_feature_branch(ForgeProtocol.feature_branch(n, role))
      end
    end
  end

  describe "route_marker/2 + parse_route_marker/1" do
    test "parse∘build == identité" do
      assert {:ok, {"poc-cycle", "build"}} =
               ForgeProtocol.parse_route_marker(ForgeProtocol.route_marker("poc-cycle", "build"))
    end

    test "extrait {pipeline, stage} d'un marqueur" do
      assert {:ok, {"poc-cycle", "build"}} =
               ForgeProtocol.parse_route_marker("[lcars-route:poc-cycle:build]")
    end

    test "marqueur noyé dans du texte" do
      assert {:ok, {"poc-cycle", "review"}} =
               ForgeProtocol.parse_route_marker("blabla\n[lcars-route:poc-cycle:review]\nfin")
    end

    test "noms kebab-case OK" do
      assert {:ok, {"standard-qa", "spec-review"}} =
               ForgeProtocol.parse_route_marker("[lcars-route:standard-qa:spec-review]")
    end

    test "pas de marqueur → nil" do
      assert nil == ForgeProtocol.parse_route_marker("juste un commentaire")
      assert nil == ForgeProtocol.parse_route_marker(nil)
    end
  end

  describe "step_run_marker/2 + step_run_marker?/1 (build+parse co-localisés)" do
    test "step_run_marker? reconnaît un marqueur produit par step_run_marker" do
      assert ForgeProtocol.step_run_marker?(ForgeProtocol.step_run_marker("engineer", "deadbeef"))
    end

    test "step_run_marker? false sur un body sans marqueur / non-binaire" do
      refute ForgeProtocol.step_run_marker?("juste un commentaire")
      refute ForgeProtocol.step_run_marker?(nil)
    end
  end

  describe "result_block/1 + parse_result_block/1 (round-trip)" do
    test "extrait le map du bloc ```result (round-trip avec le format StepRunCompleter N-04)" do
      body =
        "Livrable de architect.\n\n```result\n" <>
          ~s({"severity_max":"ok","findings":0}) <> "\n```\n\n[step_run:architect:abc]"

      assert {:ok, %{"severity_max" => "ok", "findings" => 0}} =
               ForgeProtocol.parse_result_block(body)
    end

    test "pas de bloc result → nil ; JSON invalide → nil ; nil → nil" do
      assert nil == ForgeProtocol.parse_result_block("juste un commentaire\n[step_run:x:y]")
      assert nil == ForgeProtocol.parse_result_block("```result\npas du json\n```")
      assert nil == ForgeProtocol.parse_result_block(nil)
    end

    test "result_block/1 round-trip avec parse_result_block/1" do
      outputs = %{"severity_max" => "ok", "findings" => 3}
      body = "Livrable.\n" <> ForgeProtocol.result_block(outputs)

      assert {:ok, ^outputs} = ForgeProtocol.parse_result_block(body)
    end

    test "result_block/1 : map vide → \"\" (pas de bloc, donc rien à parser)" do
      assert "" == ForgeProtocol.result_block(%{})
      assert "" == ForgeProtocol.result_block(nil)
      assert nil == ForgeProtocol.parse_result_block("Livrable sans result.")
    end

    test "result_block/1 : payload > 8 KB → note, pas de JSON tronqué" do
      big = %{"blob" => String.duplicate("x", 9000)}
      block = ForgeProtocol.result_block(big)

      refute block =~ "```result"
      assert block =~ "trop volumineux"
      # la note n'est pas un bloc result valide → parse renvoie nil (jamais de JSON tronqué).
      assert nil == ForgeProtocol.parse_result_block(block)
    end
  end

  describe "system_authored?/2 (primitif de confiance)" do
    test "true ssi le login de l'auteur == bot" do
      assert ForgeProtocol.system_authored?(%{"user" => %{"login" => "lcars-bot"}}, "lcars-bot")
      refute ForgeProtocol.system_authored?(%{"user" => %{"login" => "attacker"}}, "lcars-bot")
    end

    test "false sur structure absente / bot vide / non-map" do
      refute ForgeProtocol.system_authored?(%{"body" => "no user"}, "lcars-bot")
      refute ForgeProtocol.system_authored?(%{"user" => %{"login" => "lcars-bot"}}, "")
      refute ForgeProtocol.system_authored?("pas un comment", "lcars-bot")
    end
  end
end
