defmodule Fleet.Pilot.GatekeeperSealReapTest do
  @moduledoc """
  TICKET-LIVE (2026-08-03) — the ticket-scoped producer is reaped AT THE SEAL, and nowhere else.

  Why the hook is the seal and not `pod.completed`: a completion ends a ROUND, not the ticket. The
  whole point of `slot_scope: instance` is that the producer keeps its context across its rework
  rounds (measured in production: a rejected deliverable came back to the engineer WITH a `/clear`,
  and it re-read everything cold). The merge is the ticket's end, so it is the producer's end.

  Why a reaper is needed at all: a context-long pod does NOT die on its own — `Pod`'s
  post-completion branch says it plainly ("Release only on external kill_pod or deadline timeout")
  and `PodWarden` only sweeps the SUBSTRATE of already-dead pods. Without this call, pods pile up
  to `max_pods` and the fleet wedges on a SILENT `:at_capacity`.

  async: false — the `:spawner` seam is a global config (set/restored by TestEnv).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ForgeStubs.{MergeFailForge, OkForge}
  alias Fleet.Pilot.GatekeeperSeal
  alias Fleet.TestEnv

  @moduletag :tmp_dir

  defmodule SpySync do
    def sync(_repo, _branch), do: :ok
  end

  defmodule SpySpawner do
    # Called synchronously from seal_and_merge (same process) → self() = the test.
    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end
  end

  defmodule DeadPodSpawner do
    # The NOMINAL replay case: the pod is already gone. Must stay silent, never an error path.
    def kill_pod(pod_id) do
      send(self(), {:kill_attempted, pod_id})
      {:error, :not_found}
    end
  end

  setup %{tmp_dir: tmp} do
    TestEnv.put_env_restoring(:fleet_pilot, :worktree_sync, SpySync)
    File.write!(Path.join(tmp, "gatekeeper.gitea_token"), "tok-gatekeeper")
    TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, tmp)
    :ok
  end

  test "engineer (slot_scope: instance) → its ticket pod is reaped at the seal, keyed on the ISSUE" do
    TestEnv.put_env_restoring(:fleet_pilot, :spawner, SpySpawner)

    assert :ok =
             GatekeeperSeal.seal_and_merge(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    # The id is the one the DISPATCHER builds — keyed on the issue, not the PR, not the repo.
    expected = Fleet.Pilot.PodId.for_issue("fleet/myproj", 42, "engineer")
    assert_received {:killed, ^expected}
  end

  test "architect (slot_scope: project, derived) → NEVER reaped: it outlives the ticket by design" do
    TestEnv.put_env_restoring(:fleet_pilot, :spawner, SpySpawner)

    assert :ok =
             GatekeeperSeal.seal_and_merge(OkForge, "fleet/myproj", 7, 42, "architect", [],
               base_branch: "main"
             )

    refute_received {:killed, _}
  end

  test "already-dead pod → no-op, no error path (idempotent on replay)" do
    TestEnv.put_env_restoring(:fleet_pilot, :spawner, DeadPodSpawner)

    assert :ok =
             GatekeeperSeal.seal_and_merge(OkForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    assert_received {:kill_attempted, _}
  end

  test "merge KO → NO reaping (nothing was sealed, the producer keeps working)" do
    TestEnv.put_env_restoring(:fleet_pilot, :spawner, SpySpawner)

    assert {:error, {:merge, _}} =
             GatekeeperSeal.seal_and_merge(MergeFailForge, "fleet/myproj", 7, 42, "engineer", [],
               base_branch: "main"
             )

    refute_received {:killed, _}
  end
end
