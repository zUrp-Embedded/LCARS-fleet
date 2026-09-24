defmodule Fleet.Pilot.Poller.ReconciliationReworkLockTest do
  @moduledoc """
  A producer reworking its own PR holds the PR lock through its ASSIGNED task, not through its
  pod name (`…-issue-7-engineer` reworks PR #8). Replays 2026-09-23: three reworks lost their PR
  lock as « orphan, no live pod » 50–60 s after dispatch, while the engineer was working.
  """
  use ExUnit.Case, async: false

  import Fleet.Pilot.PollerBench

  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.Poller
  alias Fleet.Pilot.PollerBench.{StepStubForge, StepStubLoader}

  defmodule ReworkSpawner do
    @moduledoc false
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-issue-7-engineer"}]
    def wake_pod(_pod_id), do: :ok
  end

  defmodule ReworkQueue do
    @moduledoc false
    def pod_status(_pod_id), do: {:ok, :assigned}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-7"}

    def list_active,
      do: [
        %{
          state: :assigned,
          metadata: %{"issue" => 7, "repo" => "lordzurp/lcars-test", "lock_pr" => 8}
        }
      ]
  end

  defmodule DeliveredQueue do
    @moduledoc false
    # Same live pod, but its task says nothing about PR #8: it owns issue #7 only.
    def pod_status(_pod_id), do: {:ok, :assigned}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-7"}
    def list_active, do: [%{state: :assigned, metadata: %{"issue" => 7}}]
  end

  defp run_two_ticks(task_queue) do
    name = :"P_rework_#{System.unique_integer([:positive])}"

    pr8 =
      PayloadFixture.pull(
        number: 8,
        state: "open",
        head_ref: "lcars/issue-7-engineer",
        label_names: ["lcars-in-flight"]
      )

    {:ok, pid} =
      Poller.start_link(
        name: name,
        human: "lordzurp",
        start_tick?: false,
        protection_reconciler: fn _repo, _opts -> :ok end,
        architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
        step_dispatch?: true,
        forge_client: StepStubForge,
        forge_opts: [_test_issues: {:ok, []}, _test_pulls: {:ok, [pr8]}, _test_pid: self()],
        loader: StepStubLoader,
        spawner: ReworkSpawner,
        task_queue: task_queue
      )

    Poller.force_poll(name)
    Poller.force_poll(name)
    GenServer.stop(pid)
  end

  test "an engineer reworking PR #8 as issue-7-engineer keeps the PR lock across two ticks" do
    run_two_ticks(ReworkQueue)
    refute_received {:remove_label, 8, "lcars-in-flight"}
  end

  test "INVERSE TWIN — a live producer whose task holds no PR lock does NOT protect PR #8" do
    # A producer that delivered must not hide a dead judge: without `lock_pr`, the lock is orphaned.
    run_two_ticks(DeliveredQueue)
    assert_received {:remove_label, 8, "lcars-in-flight"}
  end
end
