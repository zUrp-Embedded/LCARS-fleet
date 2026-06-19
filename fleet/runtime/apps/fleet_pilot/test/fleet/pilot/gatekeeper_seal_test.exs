defmodule Fleet.Pilot.GatekeeperSealTest do
  @moduledoc "Sceau de fusion UNIQUE (F-arch-MCP) : comment gatekeeper signé + merge signé, ordre comment→merge."
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
    def post_comment(_r, _n, _b, _o), do: {:ok, 1}
    def merge_pr(_r, _pr, _o), do: {:error, {:http, 409, "not fast-forward"}}
  end

  defmodule CommentFailForge do
    def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}

    def merge_pr(_r, _pr, _o) do
      send(self(), :merged)
      :ok
    end
  end

  test "comment gatekeeper (signé via gk_opts) + dédup PUIS merge signé → :ok" do
    gk_opts = [token: "GK-TOKEN"]
    assert :ok = GatekeeperSeal.seal_and_merge(OkForge, "fleet/p", 7, 42, "engineer", gk_opts)

    assert_received {:comment, "fleet/p", 42, body, c_opts}
    assert body =~ "Brique #42"
    assert body =~ "`engineer`"
    assert body =~ "[merge:pr-7]"
    # signé gatekeeper (token du gk_opts) + dédupliqué
    assert c_opts[:token] == "GK-TOKEN"
    assert c_opts[:dedup_signature] == "[merge:pr-7]"

    assert_received {:merge, "fleet/p", 7, m_opts}
    assert m_opts[:token] == "GK-TOKEN"
  end

  test "merge KO → {:error, {:merge, _}} fail-loud" do
    assert {:error, {:merge, {:http, 409, _}}} =
             GatekeeperSeal.seal_and_merge(MergeFailForge, "fleet/p", 7, 42, "engineer", [])
  end

  test "comment KO → {:error, {:seal_comment, _}} ET pas de merge (ordre comment→merge)" do
    assert {:error, {:seal_comment, {:http, 500, _}}} =
             GatekeeperSeal.seal_and_merge(CommentFailForge, "fleet/p", 7, 42, "engineer", [])

    refute_received :merged
  end
end
