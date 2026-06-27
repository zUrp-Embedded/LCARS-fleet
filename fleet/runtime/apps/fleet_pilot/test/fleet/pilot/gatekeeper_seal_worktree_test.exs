defmodule Fleet.Pilot.GatekeeperSealWorktreeTest do
  @moduledoc """
  Câblage : `seal_and_merge` DÉCLENCHE la projection du livrable sur le clone local après un merge
  réussi, et JAMAIS après un merge KO (rien n'a été fusionné → rien à projeter). Le seam `:worktree_sync`
  pointe un espion ; `seal_and_merge` tourne dans CE process (appel direct, pas de GenServer) → l'espion
  `send(self(), …)` arrive bien au test. async: false (le seam est une config globale, posée/restaurée).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.GatekeeperSeal

  defmodule OkForge do
    def post_comment(_r, _n, _b, _o), do: {:ok, 1}
    def merge_pr(_r, _pr, _o), do: :ok
  end

  defmodule MergeFailForge do
    def post_comment(_r, _n, _b, _o), do: {:ok, 1}
    def merge_pr(_r, _pr, _o), do: {:error, {:http, 409, "not fast-forward"}}
  end

  defmodule SpySync do
    # Appelé synchrone depuis seal_and_merge (même process que le test) → self() = le test.
    def sync(repo), do: send(self(), {:worktree_sync, repo})
  end

  setup do
    Application.put_env(:fleet_pilot, :worktree_sync, SpySync)
    on_exit(fn -> Application.delete_env(:fleet_pilot, :worktree_sync) end)
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
