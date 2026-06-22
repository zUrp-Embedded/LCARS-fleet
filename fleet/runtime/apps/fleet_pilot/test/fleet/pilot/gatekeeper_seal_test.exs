defmodule Fleet.Pilot.GatekeeperSealTest do
  @moduledoc "Sceau de fusion UNIQUE (F-arch-MCP) : merge signé PUIS comment gatekeeper signé. Le merge fait foi — JAMAIS de « fusionnée » avant la réalité (F-MERGE-CLAIM-BEFORE-REALITY)."
  use ExUnit.Case, async: true

  alias Fleet.Pilot.GatekeeperSeal

  defmodule OkForge do
    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, 1}
    end

    def merge_pr(repo, pr, opts) do
      send(self(), {:merge, repo, pr, opts})
      :ok
    end
  end

  defmodule MergeFailForge do
    # post_comment SIGNALE → on prouve qu'AUCUN « fusionnée » n'est posté sur un merge KO.
    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, 1}
    end

    def merge_pr(_r, _pr, _o), do: {:error, {:http, 409, "not fast-forward"}}
  end

  defmodule CommentFailForge do
    def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}

    def merge_pr(_r, _pr, _o) do
      send(self(), :merged)
      :ok
    end
  end

  test "merge signé PUIS comment gatekeeper (signé via gk_opts) + dédup → :ok" do
    gk_opts = [token: "GK-TOKEN"]
    assert :ok = GatekeeperSeal.seal_and_merge(OkForge, "fleet/p", 7, 42, "engineer", gk_opts)

    assert_received {:merge, "fleet/p", 7, m_opts}
    assert m_opts[:token] == "GK-TOKEN"

    assert_received {:comment, "fleet/p", 42, body, c_opts}
    assert body =~ "Brique #42"
    assert body =~ "`engineer`"
    assert body =~ "[merge:pr-7]"
    # signé gatekeeper (token du gk_opts) + dédup author-agnostic (sinon double-post au retry).
    assert c_opts[:token] == "GK-TOKEN"
    assert c_opts[:dedup_signature] == "[merge:pr-7]"
    assert c_opts[:dedup_any_author] == true
  end

  test "merge KO → {:error, {:merge, _}} ET AUCUN « fusionnée » posté (pas de mensonge avant la réalité)" do
    assert {:error, {:merge, {:http, 409, _}}} =
             GatekeeperSeal.seal_and_merge(MergeFailForge, "fleet/p", 7, 42, "engineer", [])

    # LE point crucial (F-MERGE-CLAIM-BEFORE-REALITY) : merge échoué → on n'a PAS prétendu « livrée et fusionnée ».
    refute_received {:comment, _, _, _, _}
  end

  test "comment KO APRÈS merge → :ok quand même (sceau best-effort, le merge fait foi)" do
    assert :ok = GatekeeperSeal.seal_and_merge(CommentFailForge, "fleet/p", 7, 42, "engineer", [])

    assert_received :merged
  end
end
