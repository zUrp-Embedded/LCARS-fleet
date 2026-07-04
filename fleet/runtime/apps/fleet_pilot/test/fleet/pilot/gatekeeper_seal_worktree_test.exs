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

    # `seal_and_merge` signe désormais EN INTERNE (`as_gatekeeper` → RoleToken) : on pointe le
    # répertoire de tokens sur un tmp VIDE (fallback système, hermétique — jamais le vrai
    # `/home/private` du runner).
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
end
