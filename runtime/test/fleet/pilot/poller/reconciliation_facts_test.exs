defmodule Fleet.Pilot.Poller.ReconciliationFactsTest do
  @moduledoc """
  `Poller.Reconciliation` measured through the tick: which locks are ORPHANS and get reclaimed
  (after the grace), which pods are QUIESCED and get reaped, and every fact that must NOT be
  mistaken for one — a live pod, an active task, a project-scoped pipe, a gatekeeper eval in
  flight. The sibling `reconciliation_unreachable_tq_test` covers the indeterminate queue.

  `async: false`, inherited from `poller_test` and not re-audited: the registered reap listener
  (`register_reap_listener!/1`) is a node-global name.
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

      # 2nd consecutive tick: orphan CONFIRMED → lock reclaimed (the next tick will re-dispatch).
      # frein-publish P3 — the log reports what was MEASURED (no live pod here), never the old
      # asserted "pod dead without completion" that declared dead a pipe idling between two
      # rework rounds (faceproof bench). The message is the diagnosis an operator will read.
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
      # Live case 2026-07-19 (#5 zombie loop): consultant idle-at-prompt 16 min after its redirect
      # verdict. Here: #8 is parked awaits-arch (in-flight lifted by await_arch), the judge pod is
      # alive with a TERMINAL task → no reason to live → reaped after the 2-tick grace.
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
          spawner: QuiescedJudgeSpawner,
          task_queue: QuiescedTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:killed, _}

      GenServer.stop(pid)
    end

    test "reap (B'): an ACTIVE-task pod is NEVER reaped even with its brick unlocked (mid-eval belt)" do
      # Gate-eval belt: a one-shot gatekeeper mid-eval works an issue whose lock may be lifted —
      # the active task (not the label) proves it is working. Same authority as the lock duty.
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
          spawner: QuiescedJudgeSpawner,
          task_queue: ActiveTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:killed, _}

      GenServer.stop(pid)
    end

    test "reap (B'): a RESIDENT project pod (no brick ref in its id) is structurally exempt" do
      # The resident eng (`<repo>-engineer`) has no `-issue-N-` ref: its lifecycle is the
      # slot-freeze, never the brick reap — even fully idle on a quiet repo.
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
          spawner: ProjectPipeSpawner,
          task_queue: QuiescedTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:killed, _}

      GenServer.stop(pid)
    end

    test "F-037: a LIVE pod with a REPO-SCOPED pod_id holds its lock (NO mis-reclaim)" do
      # Regression of the `parse_pod_ref` fix: pod_id = `<repo-slug>-issue-N-role` (repo-scoped,
      # PodId/#25). The old `^issue-`-anchored parse did NOT recognize it → empty
      # `live_owned_refs` → a LIVE pod's lock looked orphaned → mis-reclaimed after the grace.
      # Here the pod (active task on issue 8) is recognized as owner → its lock is NEVER
      # reclaimed, even after 2 ticks.
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
          spawner: LivePodSpawner,
          task_queue: ActiveTaskQueue
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "SLOT-FREEZE: a project-scoped PIPE eng holds the lock of its ACTIVE BRICK (no mis-reclaim -> no loop)" do
      # Regression of the hello-avengers loop: the project pod `<repo>-engineer` (without
      # `-issue-N-`) was recognized as owner of NO lock (parse_pod_ref -> []) -> the poller
      # reclaimed its own -> re-dispatch loop. Here the eng (active task on #8 via its issue_id
      # "issue-8") is recognized as owner -> #8 NEVER reclaimed, even after 2 ticks.
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
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueIssue8
        )

      Poller.force_poll(name)
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      GenServer.stop(pid)
    end

    test "SLOT-FREEZE: a project PIPE eng on ANOTHER brick (9) does NOT mask orphan #8 (precise scope)" do
      # The eng ONLY owns its active brick (9), not the whole repo -> a #8 lock without an active
      # pod on it stays a REAL orphan -> reclaimed after the 2-tick grace (otherwise a legitimate
      # orphan would wedge).
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
      # Bug (introduced then reverted the same day): an augmentation "PR whose parent issue is
      # owned = owned" protected the PR from the reclaim → a DEAD JUDGE's PR lock never reclaimed
      # (the PR lock in review belongs to the judge, not the producer) → judge never re-dispatched
      # = DEAD END (martine-o-matic PR#2). We do NOT derive the PR lock from issue ownership.
      # Since F-C050 the guard is DOUBLE: a `:completed` engineer does not even own its issue
      # anymore (`:completed` terminal). Here: engineer `:completed` on issue-8, PR#6 in review
      # whose judge is DEAD (no live pr-6-* pod). issue-8 is PR-backed → never reclaimed
      # (pr_issue_ids). The PR#6 lock MUST be reclaimed (2-tick grace).
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
      # F-C050: a lost OFFLOADED completion (BEAM crash/restart BEFORE the PR opening) leaves the
      # lcars-in-flight lock on the issue. The LIVE project eng whose LAST task is `:completed`
      # (delivered, publication lost) MASKED this lock forever (pod_has_active_task? counted
      # `:completed` as active) → silent permanent wedge (the poller never re-dispatches, the
      # brick is dead). `:completed` is TERMINAL (@active_states): a DELIVERED eng no longer owns
      # its lock → the orphan is reclaimed (2-tick grace), the next tick re-dispatches. Safe: the
      # legitimate publication window (push ≤30s) removes the label well before the 2nd tick
      # (grace ≈60s), and the completion sequence is idempotent (replay-safe open_pr,
      # no-op-if-absent unlock) → a late reclaim = harmless replay. DISTINCT from the martine case
      # (PR open): HERE no PR → no pr_issue_ids exclusion → the only rampart was (wrongly) the
      # `:completed` ownership.
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
          spawner: ProjectPipeSpawner,
          task_queue: ProjectTaskQueueCompletedIssue8
        )

      # 1st tick: #8 becomes a SUSPECT (2-tick grace), not reclaimed yet.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      # 2nd tick: orphan CONFIRMED → lock reclaimed (a `:completed` no longer masks). Before the
      # fix: the `:completed` eng "owned" #8 → never reclaimed (this assert failed = the F-C050
      # wedge).
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "a FAILED reclaim keeps the ref SUSPECT: the retry lands NEXT tick, not after a fresh 2-tick grace" do
      # remove_label refused by the forge (outage). The orphan was already CONFIRMED once — dropping
      # it from the suspects with the acted set would force tick3 to re-suspect and tick4 to retry
      # (while the log promised "retry next tick"). Kept suspect, the retry is genuinely at tick3.
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
          spawner: StepStubSpawner,
          task_queue: QuiescedTaskQueue
        )

      # tick1: suspect (grace). tick2: confirmed → reclaim ATTEMPTED (fails). tick3: STILL suspect →
      # retry ATTEMPTED again. Two attempts across three ticks — the old code dropped the ref at
      # tick2 and re-suspected at tick3 (one single attempt in three ticks).
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "a parked admission (:pending task, wake never landed) does NOT mask the orphan — reclaimed at the 2nd tick" do
      # wake_unreached: the pod is spawned, the lock set, the brief ENQUEUED — but the wake never
      # reached the agent (send-keys lost, the ack-driven kick loop exhausted). The task stays
      # `:pending` (never pulled = never activated). `:pending` is an ACTIVE state, so before the fix
      # the pod "owned" its lock forever (the reconciliation counted a parked pod as a working owner)
      # → silent permanent wedge (the brick is admitted but nothing ever produces its completion). The
      # PULL (get_work_item → `:assigned`) is the durable ACK that the wake landed; a `:pending`-forever
      # admission does not own → the orphan is reclaimed (2-tick grace), the next dispatch re-attempts
      # activation. The nominal enqueue→pull window (seconds) is covered by the ~60s grace.
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
          spawner: LivePodSpawner,
          task_queue: ParkedPendingTaskQueue
        )

      # 1st tick: #8 becomes a SUSPECT (2-tick grace), not reclaimed yet.
      Poller.force_poll(name)
      refute_received {:remove_label, 8, _}

      # 2nd tick: orphan CONFIRMED → lock reclaimed (a `:pending` parked pod no longer masks). Before
      # the fix: the `:pending` pod "owned" #8 → never reclaimed (this assert failed = the parked wedge).
      Poller.force_poll(name)
      assert_received {:remove_label, 8, "lcars-in-flight"}

      GenServer.stop(pid)
    end

    test "G1: lock HELD during an ACTIVE gatekeeper eval (never reclaimed, even after the grace)" do
      # Eval window: #8's producer is DONE (no live pod), the PERMANENT gatekeeper carries the
      # eval task (pod_id without a repo slug → invisible to by-pod_id refs). Without the fix,
      # the ref looked orphaned → reclaimed at the 2nd tick MID-EVAL → concurrent re-dispatch
      # (double workflow_run + phantom verdict). With the fix: the ref is owned by the active eval
      # (gate_eval_owned_refs) → never reclaimed, for as many ticks as the eval lasts.
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
      # The eval-without-executor wedge: the eval is enqueued and the lock is preserved IN ITS NAME,
      # but the gatekeeper never pulled it (wake lost, kick net exhausted) — nobody will ever judge,
      # and before the fix the reconciliation preserved the lock forever (a `:pending` eval counted
      # as ownership). The PULL is the activation proof: a never-pulled eval loses ownership on the
      # 2-tick grace → reclaim → the next dispatch re-escalates a FRESH eval (self-heal).
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
      # Multi-project: the owned ref comes from the resume_payload's repo. An eval in progress on
      # lordzurp/autre-projet#8 does not mask the orphan lordzurp/lcars-test#8 — otherwise any
      # active eval would freeze the reconciliation of ALL repos (the fix's symmetric wedge). Also
      # covers the "clobbered eval" (cleared) case: an eval outside list_active owns nothing (same
      # path — the ref becomes orphaned again → reclaim → re-dispatch → re-escalation, self-heal).
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
    # BL-6-47.3 — une enumeration de pods qui echoue est un fail-safe CORRECT (on ne reclame rien)
    # et une panne potentiellement DURABLE. Muette, elle etait indistinguable d'un tick sans rien a
    # reclamer : le `lcars-in-flight` survit a son pod indefiniment et personne ne l'apprend.
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

      # Pas d'`on_exit` pour l'arreter : l'Agent est LIE au process de test, donc il meurt avec lui.
      # La version precedente faisait `if whereis, do: stop` — un nettoyage qui DOUBLE celui du lien
      # et court avec lui : `on_exit` s'execute apres la mort du test, le couple whereis/stop n'est
      # pas atomique, et la suite complete a exhibe la course que le fichier seul cachait.
      {:ok, _} = Agent.start_link(fn -> :boom end, name: :pods_enum)

      {name, _pid} =
        start_entry_poller({:ok, []}, %{},
          spawner: FlakySpawner,
          incident_fun: fn op, subject, reason, _o ->
            send(parent, {:incident, op, subject, reason})
            :recorded
          end
        )

      log1 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      assert log1 =~ "Poller: pod enumeration FAILED"
      assert log1 =~ "an orphaned lock outlives its pod"

      # LE SUJET EST STABLE, ET CE N'EST PAS UNE ORG. Il etait `hd(state.orgs)` — arbitraire — alors
      # qu'il entre dans la cle de recurrence : activer ou reordonner un catalogue changeait la
      # signature d'une panne identique (cooldown remis a zero, re-escalade comme neuve). Le joker
      # `_org` qui tenait cette place ne pouvait pas le voir.
      assert_received {:incident, "pod_enumeration", "spawner", :spawner_unreachable}

      # Deuxieme tick EN PANNE : silence. Repeter le meme fait toutes les 30 s noierait la trace
      # qu'il existe pour lever — meme discipline que la jauge de mailbox.
      log2 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      refute log2 =~ "pod enumeration FAILED"
      refute_received {:incident, "pod_enumeration", _, _}

      # La RECUPERATION se dit : sans elle, un operateur qui a vu l'alerte ne sait pas si c'est
      # resorbe ou si le rail est mort.
      Agent.update(:pods_enum, fn _ -> :ok end)
      log3 = ExUnit.CaptureLog.capture_log(fn -> Poller.force_poll(name) end)
      assert log3 =~ "pod enumeration RECOVERED"
    end
  end
end
