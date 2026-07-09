defmodule Fleet.Pilot.GatekeeperSealWorktreeTest do
  @moduledoc """
  Câblage : `seal_and_merge` DÉCLENCHE la projection du livrable sur le clone local après un merge
  réussi, et JAMAIS après un merge KO (rien n'a été fusionné → rien à projeter). Le seam `:worktree_sync`
  pointe un espion ; `seal_and_merge` tourne dans CE process (appel direct, pas de GenServer) → l'espion
  `send(self(), …)` arrive bien au test. async: false (les seams sont des configs globales, posées/restaurées).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{MergeFailForge, OkForge}
  alias Fleet.Pilot.GatekeeperSeal
  alias Fleet.Pilot.TestEnv

  @moduletag :tmp_dir

  defmodule SpySync do
    # Appelé synchrone depuis seal_and_merge (même process que le test) → self() = le test.
    def sync(repo), do: send(self(), {:worktree_sync, repo})
  end

  setup %{tmp_dir: tmp} do
    TestEnv.put_env_restoring(:fleet_pilot, :worktree_sync, SpySync)

    # `seal_and_merge` signe EN INTERNE (`as_gatekeeper` → RoleToken) et est FAIL-CLOSED (soft-default #3 :
    # plus de fallback système). On pose un token gatekeeper résoluble dans un tmp hermétique (jamais le vrai
    # `/home/private` du runner) → le sceau procède ; ce test vérifie la projection worktree, pas le token.
    File.write!(Path.join(tmp, "gatekeeper.gitea_token"), "tok-gatekeeper")
    TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, tmp)

    :ok
  end

  test "merge OK → projection déclenchée sur le bon repo" do
    assert :ok = GatekeeperSeal.seal_and_merge(OkForge, "fleet/myproj", 7, 42, "engineer", [])
    assert_received {:worktree_sync, "fleet/myproj"}
  end

  test "merge KO → AUCUNE projection (le merge n'a pas eu lieu, rien à aligner)" do
    assert {:error, {:merge, _}} =
             GatekeeperSeal.seal_and_merge(MergeFailForge, "fleet/myproj", 7, 42, "engineer", [])

    refute_received {:worktree_sync, _}
  end

  test "soft-default #3 — token gatekeeper ABSENT → seal REFUSE (pas de merge sous le système, pas de projection)" do
    # Fail-closed : sans token de rôle gatekeeper, le sceau NE merge/close PAS sous le compte SYSTÈME
    # (escalade de privilège + mensonge de traçabilité). Il refuse via le smart-ctor `RoleIdentity` → le
    # merge n'a pas lieu, rien à projeter. (Le repli #3 : `as_role` renvoyait `forge_opts` inchangé = token
    # système gardé → merge sous lcars-system.)
    empty = Path.join(System.tmp_dir!(), "no-gk-token-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, empty)

    assert {:error, :role_token_unavailable} =
             GatekeeperSeal.seal_and_merge(OkForge, "fleet/myproj", 7, 42, "engineer", [])

    refute_received {:worktree_sync, _}
  end
end
