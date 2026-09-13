defmodule Fleet.Pilot.MergeAndPromoteReapTest do
  @moduledoc """
  Checks reaping requests after nominal/out-of-band merge, scope exclusion and
  not_found handling. Round completion must retain ticket-producer rework context;
  terminal reaping requests its removal. These spies do not prove capacity release, pod death
  or exclusivity of the reaping hook. Global pilot_spawner config requires async:false.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{MergeFailForge, OkForge}
  alias Fleet.Pilot.MergeAndPromote
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  defmodule SpySync do
    def sync(_repo, _branch), do: :ok
  end

  defmodule SpySpawner do
    # Called synchronously from merge_and_promote (same process) → self() = the test.
    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end
  end

  defmodule DeadPodSpawner do
    def kill_pod(pod_id) do
      send(self(), {:kill_attempted, pod_id})
      {:error, :not_found}
    end
  end

  setup %{tmp_dir: tmp} do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_worktree_sync, SpySync)
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

    TestEnv.put_role_token!("gatekeeper", "tok-gatekeeper")
    TestEnv.put_role_token!("chief", "tok-chief")
    :ok
  end

  test "engineer (slot_scope: instance) → its ticket pod is reaped at the seal, keyed on the ISSUE" do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, SpySpawner)

    assert :ok =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    # Compare against the dispatch identity keyed by repo, issue and role.
    expected = Fleet.PodId.for_issue("fleet/myproj", 42, "engineer")
    assert_received {:killed, ^expected}
  end

  test "architect (slot_scope: project, derived) → NEVER reaped: it outlives the ticket by design" do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, SpySpawner)

    assert :ok =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/myproj", 7, 42, "architect", [],
               base_branch: "main"
             )

    refute_received {:killed, _}
  end

  test "already-dead pod → no-op, no error path (idempotent on replay)" do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, DeadPodSpawner)

    assert :ok =
             MergeAndPromote.merge_and_promote(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:kill_attempted, _}
  end

  test "merge KO → NO reaping (nothing was sealed, the producer keeps working)" do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, SpySpawner)

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

    refute_received {:killed, _}
  end

  test "merge HORS BANDE → moisson aussi : la fuite ne doit pas dépendre de QUI a mergé" do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, SpySpawner)

    assert :ok =
             MergeAndPromote.converge_out_of_band_merge(OkForge, "fleet/myproj", 7, 42, [],
               base_branch: "main",
               producer: "engineer"
             )

    expected = Fleet.PodId.for_issue("fleet/myproj", 42, "engineer")
    assert_received {:killed, ^expected}
  end

  test "hors bande SANS producteur nommable → aucune moisson, jamais une identité devinée" do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, SpySpawner)

    assert :ok =
             MergeAndPromote.converge_out_of_band_merge(OkForge, "fleet/myproj", 7, 42, [],
               base_branch: "main"
             )

    refute_received {:killed, _}
  end
end
