defmodule Fleet.Pilot.Poller.ReconciliationFactsTest do
  @moduledoc """
  Exercises reconciliation through full poll calls with forge, spawner and broker
  doubles: lock ownership, quiesced pods, project-task references and gate evaluations.
  These calls advance grace without elapsed-time or real publication-race guarantees.
  ReconciliationUnreachableTqTest covers uncertain broker reads.

  Serialized because the reap listener and fixture agents use global names.
  """
  use ExUnit.Case, async: false

  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.Poller

  import Fleet.Pilot.PollerBench

  alias Fleet.Pilot.PollerBench.{
    ActiveTaskQueue,
    GateEvalOtherRepoTaskQueue,
    GateEvalPendingTaskQueue,
    GateEvalTaskQueue,
    LivePodSpawner,
    ParkedPendingTaskQueue,
    ProjectPipeSpawner,
    ProjectTaskQueueCompletedIssue8,
    ProjectTaskQueueIssue8,
    ProjectTaskQueueIssue9,
    QuiescedJudgeSpawner,
    QuiescedTaskQueue,
    StepStubForge,
    StepStubLoader,
    StepStubSpawner
  }

  # Stub architect maintenance to avoid reading the user's durable pod state.

  describe "reconciliation — orphan locks and quiesced pods" do
    test "reconciliation (B): orphan lock reclaimed at the 2nd tick (grace), not the 1st" do
      # #8 locked but NO live pod (StepStubSpawner.list_pods → []) = confirmed orphan.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      {name, pid} = start_step_poller({:ok, issues})

      # 1st tick: #8 becomes a SUSPECT (2-tick grace) — NOT reclaimed yet.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      # Confirm the second observation attempts removal and diagnoses an empty snapshot.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Poller.force_poll(name)
          assert_received {:remove_label, 8, "lcars-in-flight"}
        end)

      assert log =~ "no live pod (dead/reaped)"
      refute log =~ "pod dead without completion"

      GenServer.stop(pid)
    end

    test "reap (B'): a QUIESCED judge pod (brick unlocked, no active task) is reaped at the 2nd tick, not the 1st" do
      # An unlocked instance pod with terminal work should be reaped after confirmation.
      register_reap_listener!()

      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-awaits-arch"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_reap_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: QuiescedJudgeSpawner,
          task_queue: QuiescedTaskQueue
        )

      # 1st tick: the pod becomes a SUSPECT (2-tick grace) — NOT reaped yet.
      Poller.force_poll(name)
      refute_received {:killed, _}

      # 2nd consecutive tick: quiesced CONFIRMED → reaped.
      Poller.force_poll(name)
      assert_received {:killed, "lordzurp-lcars-test-issue-8-consultant"}

      GenServer.stop(pid)
    end

    test "reap (B'): a pod whose brick STILL holds the in-flight lock is NEVER reaped" do
      register_reap_listener!()

      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_reap_locked_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: QuiescedJudgeSpawner,
          task_queue: QuiescedTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:killed, _}

      GenServer.stop(pid)
    end

    test "reap (B'): an ACTIVE-task pod is NEVER reaped even with its brick unlocked (mid-eval belt)" do
      # Active work protects a pod from reaping even without its lock in the listing.
      register_reap_listener!()

      issues = [
        PayloadFixture.issue(number: 8, body: "x", label_names: [], assignee_logins: ["lordzurp"])
      ]

      name = :"P_reap_active_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: QuiescedJudgeSpawner,
          task_queue: ActiveTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:killed, _}

      GenServer.stop(pid)
    end

    test "reap (B'): a RESIDENT project pod (no brick ref in its id) is structurally exempt" do
      # Project IDs carry no instance reference and remain outside this reap duty.
      register_reap_listener!()

      name = :"P_reap_resident_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, []}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: ProjectPipeSpawner,
          task_queue: QuiescedTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:killed, _}

      GenServer.stop(pid)
    end

    test "F-037: a LIVE pod with a REPO-SCOPED pod_id holds its lock (NO mis-reclaim)" do
      # Recognize the repo-prefixed instance ID as owner while its task is assigned.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_live_lock_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: LivePodSpawner,
          task_queue: ActiveTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "SLOT-FREEZE: a project-scoped PIPE eng holds the lock of its ACTIVE BRICK (no mis-reclaim -> no loop)" do
      # Project IDs need active-task identity to protect the specific issue lock.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_proj_lock_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueIssue8
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "SLOT-FREEZE: a project PIPE eng on ANOTHER brick (9) does NOT mask orphan #8 (precise scope)" do
      # Active issue 9 must not protect issue 8 merely by sharing its repository.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_proj_other_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueIssue9
        )

      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "martine REGRESSION: a :completed engineer owning the issue does NOT protect a dead judge's PR lock" do
      # A producer must not protect its judge's PR lock. Here completed work also
      # owns no issue lock; the open PR separately excludes issue-lock reclamation.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      pulls = [
        PayloadFixture.pull(
          number: 6,
          head_ref: "lcars/issue-8-engineer",
          label_names: ["lcars-in-flight"]
        )
      ]

      name = :"P_pr_orphan_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pulls: {:ok, pulls}, _test_pid: self()],
          loader: StepStubLoader,
          # LIVE project-scoped engineer, `:completed` task (delivered) on issue-8 — the martine config.
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueCompletedIssue8
        )

      # issue #8: PR-backed → excluded from the issue-orphan scan, ISSUE lock never reclaimed
      # (doctrine). PR #6: the judge is dead → orphan lock CONFIRMED, reclaimed after the 2-tick
      # grace (2nd poll).
      Poller.force_poll(name)
      refute_received {:remove_label, 6, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 6, _}
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "F-C050: a :completed PIPE eng (publication LOST, NO PR) does NOT mask the orphan — reclaimed at the 2nd tick" do
      # Completed producer work with no PR must not mask a leftover issue lock.
      # This checks eventual reclaim, not crash recovery or harmless concurrent replay.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_c050_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          # NO _test_pulls → no PR: the publication was lost BEFORE open_pr.
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          # LIVE project eng, last task `:completed` (delivered) on issue-8 — publication lost.
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueCompletedIssue8
        )

      # 1st tick: #8 becomes a SUSPECT (2-tick grace), not reclaimed yet.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      # Completed work no longer prevents reclaim on the confirming observation.
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "a FAILED reclaim keeps the ref SUSPECT: the retry lands NEXT tick, not after a fresh 2-tick grace" do
      # A failed confirmed reclaim keeps its history so the next observation retries.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_reclaim_retry_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [
            _test_issues: {:ok, issues},
            _test_pid: self(),
            _test_fail_remove_label: true
          ],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: StepStubSpawner,
          task_queue: QuiescedTaskQueue
        )

      # Seed once, then observe two consecutive removal attempts despite failure.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "a parked admission (:pending task, wake never landed) does NOT mask the orphan — reclaimed at the 2nd tick" do
      # Pending work may represent a lost wake. It protects pod lifetime but must not
      # indefinitely mask the lock. Actual enqueue-to-pull timing is outside this test.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_rf21_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          # LIVE instance pod (issue-8-engineer) whose task is `:pending` — admitted, never activated.
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: LivePodSpawner,
          task_queue: ParkedPendingTaskQueue
        )

      # 1st tick: #8 becomes a SUSPECT (2-tick grace), not reclaimed yet.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      # Pending work must not prevent the confirming reclaim.
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "G1: lock HELD during an ACTIVE gatekeeper eval (never reclaimed, even after the grace)" do
      # Gate-evaluation metadata must protect its issue even without an instance pod ID.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_g1_eval_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: StepStubSpawner,
          task_queue: GateEvalTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "a gate-eval stuck :pending (never pulled — no executor) does NOT hold the lock: reclaimed at the 2nd tick" do
      # A pending evaluation has no pulled executor and must not retain lock ownership.
      # This test stops at reclaim; it does not prove the subsequent evaluation succeeds.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_g1_pending_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: StepStubSpawner,
          task_queue: GateEvalPendingTaskQueue
        )

      # 1st tick: suspect (grace). 2nd tick: confirmed → reclaimed (before the fix: owned forever).
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "G1: a gatekeeper eval of ANOTHER repo does NOT hold the lock (reclaimed at the 2nd tick)" do
      # An assigned evaluation for another repo must not mask this repo's orphan.
      # Cleared-evaluation behavior is not independently exercised here.
      issues = [
        PayloadFixture.issue(
          number: 8,
          body: "x",
          label_names: ["lcars-in-flight"],
          assignee_logins: ["lordzurp"]
        )
      ]

      name = :"P_g1_other_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Poller.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [_test_issues: {:ok, issues}, _test_pid: self()],
          loader: StepStubLoader,
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: StepStubSpawner,
          task_queue: GateEvalOtherRepoTaskQueue
        )

      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end
  end

  describe "the pod enumeration — a fact said on its transition" do
    # Distinguish a failed snapshot from an ordinary pass with no orphans.
    defmodule FlakySpawner do
      def spawn_pod(p, i, o), do: StepStubSpawner.spawn_pod(p, i, o)
      def wake_pod(a), do: StepStubSpawner.wake_pod(a)

      def list_pods do
        case Agent.get(:pods_enum, & &1) do
          :ok -> []
          :boom -> raise "spawner injoignable"
        end
      end
    end

    test "enumeration des pods KO : on parle au FRANCHISSEMENT, une fois — pas a chaque tick" do
      parent = self()

      # The agent is linked to the test; avoid a redundant whereis/stop teardown race.
      {:ok, _} = Agent.start_link(fn -> :boom end, name: :pods_enum)

      {name, _pid} =
        start_entry_poller({:ok, []}, %{},
          architect_keeper: fn _repo, _opts -> {:ok, :stub} end,
          spawner: FlakySpawner,
          incident_fun: fn op, subject, reason, _o ->
            send(parent, {:incident, op, subject, reason})
            :recorded
          end
        )

      log1 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      assert log1 =~ "Poller: pod enumeration FAILED"
      assert log1 =~ "an orphaned lock outlives its pod"

      # The incident subject must be stable across catalogue additions and reorderings.
      assert_received {:incident, "pod_enumeration", "spawner", :spawner_unreachable}

      # A continuing snapshot failure must not repeat the transition incident.
      log2 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      refute log2 =~ "pod enumeration FAILED"
      refute_received {:incident, "pod_enumeration", _, _}

      # Report recovery so the last visible state is not a permanent stale alert.
      Agent.update(:pods_enum, fn _ -> :ok end)
      log3 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      assert log3 =~ "pod enumeration RECOVERED"
    end
  end
end
