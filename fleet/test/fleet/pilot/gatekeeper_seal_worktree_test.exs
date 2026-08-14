defmodule Fleet.Pilot.GatekeeperSealWorktreeTest do
  @moduledoc """
  Wiring: `seal_and_merge` TRIGGERS the deliverable projection onto the local clone after a
  successful merge, and NEVER after a failed merge (nothing was merged → nothing to project). The
  `:worktree_sync` seam points to a spy; `seal_and_merge` runs in THIS process (direct call, no
  GenServer) → the spy's `send(self(), …)` does reach the test. async: false (seams are global
  configs, set/restored).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{CloseFailForge, MergeFailForge, OkForge}
  alias Fleet.Pilot.GatekeeperSeal
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  defmodule SpySync do
    # Called synchronously from seal_and_merge (same process as the test) → self() = the test.
    def sync(repo, branch), do: send(self(), {:worktree_sync, repo, branch})
  end

  setup %{tmp_dir: tmp} do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_worktree_sync, SpySync)

    # `seal_and_merge` signs INTERNALLY (`as_gatekeeper` → RoleToken) and is FAIL-CLOSED
    # (soft-default #3: no system fallback). We place a resolvable gatekeeper token in a hermetic tmp
    # (never the runner's real `/home/private`) → the seal proceeds; this test verifies the worktree
    # projection, not the token.
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)
    Fleet.TestEnv.put_role_token!("gatekeeper", "tok-gatekeeper")

    :ok
  end

  test "merge OK → projection triggered on the right repo" do
    assert :ok =
             GatekeeperSeal.seal_and_merge(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:worktree_sync, "fleet/myproj", "main"}
  end

  test "merge KO → NO projection (the merge did not happen, nothing to align)" do
    assert {:error, {:merge, _}} =
             GatekeeperSeal.seal_and_merge(MergeFailForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    refute_received {:worktree_sync, _, _}
  end

  test "soft-default #3 — gatekeeper token ABSENT → seal REFUSES (no merge as system, no projection)" do
    # Fail-closed: without a gatekeeper role token, the seal does NOT merge/close under the SYSTEM
    # account (privilege escalation + traceability lie). It refuses via the `RoleIdentity` smart-ctor
    # → the merge does not happen, nothing to project. (Fallback #3: an `as_role` returning
    # `forge_opts` unchanged = system token kept → merge as lcars-system.)
    empty = Path.join(System.tmp_dir!(), "no-gk-token-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, empty)

    assert {:error, :role_token_unavailable} =
             GatekeeperSeal.seal_and_merge(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    refute_received {:worktree_sync, _, _}
  end

  test "F-C066 — merge OK but close FAILS (persistent) → seal {:error, {:close_after_merge, _}} + LOUD log, projection anyway" do
    # A discarded `_ = close_issue` → failed close → seal returning `:ok` → MERGED brick stays OPEN →
    # re-dispatched every tick, in SILENCE (the RETURN lied). F-C066: HONEST return (the merge
    # succeeded but the close did not) after bounded retry + LOUD log. The caller then skips the
    # unlock (issue keeps lcars-in-flight) and `decide/1` skips `stage/merged` → never re-dispatched.
    # Token placed by the setup.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:close_after_merge, _}} =
                 GatekeeperSeal.seal_and_merge(
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

    # The merge did happen → the worktree projection IS triggered (the failed close does not
    # invalidate the merge).
    assert_received {:worktree_sync, "fleet/myproj", "main"}
  end
end
