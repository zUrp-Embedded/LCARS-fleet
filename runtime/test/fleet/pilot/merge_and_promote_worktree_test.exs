defmodule Fleet.Pilot.MergeAndPromoteWorktreeTest do
  @moduledoc """
  Checks sync requests with a same-process spy and temporary role tokens.
  A returned merge failure without positive readback does not trigger sync; close
  or decision-token failure after merge does. This does not run synchronization
  or prove disk convergence. Global seams require synchronous tests.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{CloseFailForge, MergeFailForge, OkForge}
  alias Fleet.Pilot.MergeAndPromote
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  defmodule SpySync do
    def sync(repo, branch), do: send(self(), {:worktree_sync, repo, branch})
  end

  setup %{tmp_dir: tmp} do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_worktree_sync, SpySync)

    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
    TestEnv.put_role_token!("gatekeeper", "tok-gatekeeper")
    TestEnv.put_role_token!("chief", "tok-chief")

    :ok
  end

  test "merge OK → projection triggered on the right repo" do
    assert :ok =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:worktree_sync, "fleet/myproj", "main"}
  end

  test "merge KO → NO projection (the merge did not happen, nothing to align)" do
    assert {:error, {:merge, _}} =
             MergeAndPromote.merge_and_promote(
               MergeFailForge,
               "fleet/myproj",
               7,
               42,
               "engineer",
               [],
               base_branch: "main"
             )

    refute_received {:worktree_sync, _, _}
  end

  test "soft-default #3 — jeton du rail MERGE absent → refus AVANT toute tentative, rien a projeter" do
    # Remove only the merge token. The paired test removes only the decision token:
    # clearing both could not distinguish which identity caused the refusal.
    TestEnv.delete_role_token!("chief")

    assert {:error, :role_token_unavailable} =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    refute_received {:merge, _, _, _}
    refute_received {:comment, _, _, _, _}
    refute_received {:worktree_sync, _, _}
  end

  test "jeton du rail DECISION absent APRES un merge reussi → close_after_merge, et la projection a lieu" do
    # The remaining merge token permits the merge request; the missing decision token
    # must not fall back to system credentials for promotion or close.
    TestEnv.delete_role_token!("gatekeeper")

    assert {:error, {:close_after_merge, :role_token_unavailable}} =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    # Filter the promotion signature: a system provenance note may still be posted.
    # This case asserts sync and forbidden promotion/close, not the merge message itself.
    msgs = drain_mailbox()

    refute Enum.any?(msgs, fn
             {:comment, _, _, _, opts} -> opts[:dedup_signature] == "[merge:pr-7]"
             _ -> false
           end),
           "le commentaire de promotion ne doit PAS partir sans le jeton du rail décision"

    refute Enum.any?(msgs, &match?({:close_issue, _, _, _}, &1)),
           "la fermeture est un acte du rail décision — pas de jeton, pas de fermeture"

    assert Enum.any?(msgs, &match?({:worktree_sync, "fleet/myproj", "main"}, &1)),
           "la brique EST fusionnée : la projection a lieu quoi qu'il arrive à la cérémonie"
  end

  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "F-C066 — merge OK but close FAILS (persistent) → seal {:error, {:close_after_merge, _}} + LOUD log, projection anyway" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:close_after_merge, _}} =
                 MergeAndPromote.merge_and_promote(
                   CloseFailForge,
                   "fleet/myproj",
                   7,
                   42,
                   "engineer",
                   [],
                   base_branch: "main"
                 )
      end)

    assert log =~ "close FAILED"

    assert_received {:worktree_sync, "fleet/myproj", "main"}
  end
end
