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

    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
    def close_issue(_r, _n, _o), do: {:ok, :closed}
  end

  # F-C066 — merge/comment/stage OK, close TOUJOURS en échec : prouve le retour honnête (pas de :ok menteur).
  defmodule CloseFailForge do
    def merge_pr(_r, _pr, _o), do: :ok
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}

    def close_issue(_r, n, _o) do
      send(self(), {:close_attempt, n})
      {:error, {:http, 500, "close boom"}}
    end
  end

  # F-C066 — close FLAKY : échoue 2×, réussit la 3e (compteur process-dict) → prouve l'auto-heal par retry.
  defmodule CloseFlakyForge do
    def merge_pr(_r, _pr, _o), do: :ok
    def post_comment(_r, _n, _b, _o), do: {:ok, :posted}
    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}

    def close_issue(_r, n, _o) do
      attempt = (Process.get({:close_attempts, n}) || 0) + 1
      Process.put({:close_attempts, n}, attempt)
      send(self(), {:close_attempt, n, attempt})
      if attempt < 3, do: {:error, {:http, 500, "flaky"}}, else: {:ok, :closed}
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

    # Close explicite SIGNÉ GATEKEEPER (régression QoL 2026-07-07 : partait signé système — rupture
    # d'identité dans le sceau alors que merge+comment sont DÉJÀ gatekeeper, cf. ci-dessus).
    assert_received {:close_issue, "fleet/p", 42, close_opts}
    assert close_opts[:token] == "GK-TOKEN"
  end

  test "merge KO → {:error, {:merge, _}} ET AUCUN « fusionnée » posté (pas de mensonge avant la réalité)" do
    assert {:error, {:merge, {:http, 409, _}}} =
             GatekeeperSeal.seal_and_merge(MergeFailForge, "fleet/p", 7, 42, "engineer", [])

    # LE point crucial (F-MERGE-CLAIM-BEFORE-REALITY) : merge échoué → on n'a PAS prétendu « livrée et fusionnée ».
    refute_received {:comment, _, _, _, _}
  end

  # Le merge est l'acte qui fait foi ; le comment est une trace post-merge JETÉE SANS LOG par
  # seal_and_merge — la trace lisible manque alors sur l'issue et rien ne la re-poste (le dedup ne
  # garde que contre les replays). Seule la trace humaine est perdue, jamais le merge.
  test "comment KO APRÈS merge → :ok quand même (le merge fait foi, la trace est perdue en silence)" do
    assert :ok = GatekeeperSeal.seal_and_merge(CommentFailForge, "fleet/p", 7, 42, "engineer", [])

    assert_received :merged
  end

  test "F-C066 : merge OK mais close échoué (persistant) → {:error, {:close_after_merge, _}}, JAMAIS un :ok menteur" do
    # Le cœur du finding : la fonction retournait `:ok` même quand `close_issue` échouait (log-loud puis
    # `:ok`) → l'appelant croyait la brique scellée alors que l'issue restait OPEN → re-dispatch →
    # double-livraison. Désormais : retour HONNÊTE typé (le merge a réussi, mais le close non).
    assert {:error, {:close_after_merge, {:http, 500, "close boom"}}} =
             GatekeeperSeal.seal_and_merge(CloseFailForge, "fleet/p", 7, 42, "engineer", [])

    # Retry BORNÉ : 3 tentatives de close avant d'abandonner (puis retour honnête).
    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    assert_received {:close_attempt, 42}
    refute_received {:close_attempt, 42}
  end

  test "F-C066 : close flaky (échoue 2×, réussit la 3e) → retry → :ok (auto-heal d'un blip transitoire)" do
    assert :ok = GatekeeperSeal.seal_and_merge(CloseFlakyForge, "fleet/p", 7, 42, "engineer", [])

    assert_received {:close_attempt, 42, 1}
    assert_received {:close_attempt, 42, 2}
    assert_received {:close_attempt, 42, 3}
  end
end
