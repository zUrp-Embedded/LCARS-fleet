defmodule Fleet.Pilot.GatekeeperSealTest do
  @moduledoc """
  Sceau de fusion UNIQUE (F-arch-MCP) : merge signé PUIS comment gatekeeper signé. Le merge fait
  foi — JAMAIS de « fusionnée » avant la réalité (F-MERGE-CLAIM-BEFORE-REALITY). La signature
  gatekeeper est posée EN INTERNE par `seal_and_merge` (`as_gatekeeper` → RoleToken) : le token du
  compte gatekeeper vient d'un tmp_dir contrôlé (jamais le vrai `/home/private` du runner).
  async: false (mute la config globale `:role_tokens_dir`).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{MergeFailForge, OkForge}
  alias Fleet.Pilot.GatekeeperSeal
  alias Fleet.Pilot.TestEnv

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # Token de rôle gatekeeper résoluble → `seal_and_merge` doit signer merge ET comment avec.
    File.write!(Path.join(tmp, "gatekeeper.gitea_token"), "GK-TOKEN")
    TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, tmp)

    :ok
  end

  defmodule CommentFailForge do
    def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}

    def merge_pr(_r, _pr, _o) do
      send(self(), :merged)
      :ok
    end
  end

  test "merge signé PUIS comment gatekeeper (signature interne as_gatekeeper) + dédup → :ok" do
    # forge_opts BRUTS (token système) : la signature gatekeeper doit être posée EN INTERNE par
    # `seal_and_merge` (writer unique `as_gatekeeper`) — le token de rôle ÉCRASE le système.
    forge_opts = [token: "system-token"]
    assert :ok = GatekeeperSeal.seal_and_merge(OkForge, "fleet/p", 7, 42, "engineer", forge_opts)

    assert_received {:merge, "fleet/p", 7, m_opts}
    assert m_opts[:token] == "GK-TOKEN"

    assert_received {:comment, "fleet/p", 42, body, c_opts}
    assert body =~ "Brique #42"
    assert body =~ "`engineer`"
    assert body =~ "[merge:pr-7]"

    # signé gatekeeper (token de rôle, posé en interne) + dédup author-agnostic (sinon double-post au retry).
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
