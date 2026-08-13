defmodule Fleet.Pilot.StepDispatcherTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher
  alias Fleet.Pilot.StubTaskQueue

  defp issue(fields) do
    %{
      "issue" =>
        Map.merge(
          %{"number" => 42, "body" => "fais le hello", "labels" => [], "assignees" => []},
          fields
        )
    }
  end

  # Producer issue of the forge-state-machine model (DN §1): assignee = the owning HUMAN. The
  # producer role is a poller-side INVARIANT (`:producer_role`, default engineer), not a per-issue
  # marker. `fields` overrides (labels, body…).
  defp eng_issue(fields \\ %{}) do
    issue(Map.merge(%{"assignees" => [%{"login" => "lordzurp"}]}, fields))
  end

  # #5.2 D2 — decide = pure GATE: lock → skip, otherwise :engage. No ownership (forge-side scoping
  # upstream), no role (comes from the route via workflow_map_role), no load (workflow_map_role loads).
  describe "decide/1 (pure gate)" do
    test "unlocked issue → :engage (role AND spawn/onboard action decided downstream)" do
      assert :engage = StepDispatcher.decide(eng_issue())
    end

    test "lcars-in-flight lock present → {:skip, :in_flight}" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}]})
      assert {:skip, :in_flight} = StepDispatcher.decide(payload)
    end

    test "HUMAN lock lcars-awaits-arch → {:skip, :awaits_arch} (A2.3b, no re-dispatch)" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-awaits-arch"}]})
      assert {:skip, :awaits_arch} = StepDispatcher.decide(payload)
    end

    test "F-C066: stage/merged label → {:skip, :merged} (TERMINAL merged brick, never re-engaged)" do
      # A merged brick whose explicit close failed (issue left OPEN, lock possibly reclaimed by the
      # reconciliation) must NOT be re-dispatched → otherwise double-delivery. The `stage/merged`
      # label (set BEFORE the close) is the DURABLE guard, independent of the lcars-in-flight lock.
      payload = eng_issue(%{"labels" => [%{"name" => "stage/merged"}]})
      assert {:skip, :merged} = StepDispatcher.decide(payload)
    end
  end

  # Stub seams for dispatch_issue/2
  defmodule StubForge do
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def start_stopwatch(_repo, _n, _opts), do: :ok

    # Regression guard: signals `n` — proves that `promote_pr` (poller-driven merge,
    # no-workflow_map) NOW lifts the ISSUE lock in addition to the PR lock.
    def stop_stopwatch(_repo, n, _opts) do
      send(self(), {:stopped_watch, n})
      :ok
    end

    # Adoption: sets judges on an orphan PR (human/fork). Captured for assertion.
    def request_review(_repo, index, reviewers, _opts) do
      send(self(), {:requested_review, index, reviewers})
      :ok
    end

    # A2.1: route read from forge_opts[:_test_route] (default :none = out-of-workflow_map / 1-step).
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)

    # #5.2 D2 — onboarding: records the default workflow_map's initial route. Captured for assertion.
    def post_route(_repo, n, workflow_map, step, _opts) do
      send(self(), {:routed, n, workflow_map, step})
      {:ok, :posted}
    end

    # F077: the judge brief reads the predecessor's result (option B). Stub: forge_opts[:_test_pred].
    def get_predecessor_result(_repo, _n, opts), do: Keyword.get(opts, :_test_pred, :none)

    # Info-starvation fix: build_judge_brief reads the criterion (issue body) via get_issue.
    # Stub: forge_opts[:_test_issue_body] (default a non-empty body).
    def get_issue(_repo, n, opts),
      do: {:ok, %{"number" => n, "body" => Keyword.get(opts, :_test_issue_body, "critère stub")}}

    # ②.1d: per-judge verdicts (reviews-driven). Stub: forge_opts[:_test_verdicts] (map
    # login↓→verdict, default %{} = no judge has a decisive verdict yet).
    def pr_review_verdicts(_repo, _index, opts),
      do: {:ok, Keyword.get(opts, :_test_verdicts, %{})}

    # F-E8: combined jury state (verdicts + jury SET from the review-records). `:_test_reviewers`
    # (default [] → `requested` = only the PR's `requested_reviewers`, legacy test behavior).
    def pr_review_state(_repo, _index, opts),
      do:
        {:ok,
         %{
           verdicts: Keyword.get(opts, :_test_verdicts, %{}),
           reviewers: Keyword.get(opts, :_test_reviewers, [])
         }}

    # Info-starvation fix (rework): REQUEST_CHANGES feedback injected into the rework brief. Stub:
    # forge_opts[:_test_feedback] (list of %{"login","body"}, default a non-empty body).
    def change_request_feedback(_repo, _index, opts),
      do:
        {:ok,
         Keyword.get(opts, :_test_feedback, [%{"login" => "reviewer", "body" => "feedback stub"}])}

    # MA-06: forge-native counter of rework rounds (nb of REQUEST_CHANGES). Stub:
    # forge_opts[:_test_rework_rounds] (default 0 = no round → normal re-spawn, legacy tests unchanged).
    def count_change_request_rounds(_repo, _index, opts),
      do: Keyword.get(opts, :_test_rework_rounds, {:ok, 0})

    # Publish brake (chantier frein-publish): largest same-base [publish-fail:...] group.
    # Default 0 = no failure recorded → the brake never fires (legacy tests unchanged).
    def count_publish_failures(_repo, _n, opts),
      do: Keyword.get(opts, :_test_publish_fails, {:ok, 0})

    # Tier 1 (conflict-rework budget): counts the `[conflict-rework:pr-N` markers. Seam
    # `_test_conflict_rounds` (default {:ok, 0} = first conflict → producer rework, not escalation).
    def count_comments_marked(_repo, _index, _prefix, opts),
      do: Keyword.get(opts, :_test_conflict_rounds, {:ok, 0})

    # F181: compensation — lock removal on a post-lock failure. Seam `_test_remove_label` (default
    # {:ok, :removed}) lets a test force the removal to FAIL (CI-10: honest "lock removal FAILED" log).
    def remove_label(_repo, _n, label, opts) do
      send(self(), {:removed_label, label})
      Keyword.get(opts, :_test_remove_label, {:ok, :removed})
    end

    # ②.1d: FF merge (PR-state-driven promote, all judges OK). Signals for assertion.
    # `_test_merge_result` (seam) forces a failure (e.g. conflict `{:error, {:http, 409, _}}`) →
    # tests the F-PARALLEL-PR-CONFLICT resolution; absent → success `:ok`.
    def merge_pr(_repo, index, opts) do
      case Keyword.get(opts, :_test_merge_result) do
        nil ->
          send(self(), {:merged, index})
          :ok

        result ->
          result
      end
    end

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def close_issue(_repo, _n, _opts), do: {:ok, :closed}

    # PR object re-read by `route_merge_failure` to CLASSIFY a merge failure (MergeOutcome). Seam
    # `_test_pull` (map of mergeable/draft/state fields); default = real git conflict (mergeable:false).
    # The default carries a `head` because a real PR object always does, and a double that omits a
    # field the real seam always fills does not simplify a test — it hides a caller. `CiGate` reads
    # this head, and its absence surfaced as `{:no_head_sha, …}`, a shape the forge cannot produce.
    def get_pull(_repo, n, opts) do
      {:ok,
       Keyword.get(opts, :_test_pull, %{
         "number" => n,
         "state" => "open",
         "draft" => false,
         "mergeable" => false,
         "head" => %{"sha" => "d15pa7c4ed0000000000"},
         "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       })}
    end

    # Re-requested judges (timeline) — `_test_rerequested` seam (default none).
    def pr_rerequested_reviewers(_repo, _n, opts),
      do: {:ok, Keyword.get(opts, :_test_rerequested, [])}

    # CI state on the head — `_test_ci` seam. Default `:none` (repo without a CI rail), which is
    # what every pre-existing test of this module describes: their policy blocks are re-requests.
    def commit_ci_state(_repo, _sha, opts),
      do: {:ok, Keyword.get(opts, :_test_ci, :none)}
  end

  defmodule StubLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    # F077: a judge role declares `brief_kind: judge` in its cap-profile (not a magic name).
    def load("gatekeeper"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "gatekeeper"},
           spec: %{"brief_kind" => "judge", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    # A PR judge (qualifier/reviewer) also declares brief_kind: judge.
    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"brief_kind" => "judge"}
         }}

    # #8: the consultant re-reads the BRIEF (judge) → brief_kind: judge.
    def load("consultant"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "consultant"},
           spec: %{"brief_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  defmodule StubSpawner do
    # Faithful to the real `Spawner.spawn_pod/3` contract: returns `{:ok, pid()}`, NOT a string
    # (a string return masked the PID interpolation bug caught by the PASSE-9 dogfood).
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    def wake_pod(pod_id) do
      send(self(), {:woke, pod_id})
      :ok
    end

    # F181: compensation — `safe_kill` of the pod before lock removal. A failed kill is not
    # retried: lock removed → re-dispatch next tick, which RE-BRIEFS the still-alive pod
    # (idempotent dispatch); the orphan substrate is swept by the Spawner's PodWarden.
    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end
  end

  # Spawner whose pod is ALREADY ALIVE (`pod_info` → `{:ok, _}`). Used to test the serialization
  # GATE: a project-scoped role already alive → the dispatcher DEFERS (`:role_busy`), it neither
  # spawns nor rebriefs a busy pod. (Rebrief-on-alive stays possible for `instance` scoped ones.)
  defmodule StubSpawnerAlive do
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    def wake_pod(pod_id) do
      send(self(), {:woke, pod_id})
      :ok
    end

    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end

    def pod_info(pod_id) do
      send(self(), {:pod_info, pod_id})
      {:ok, %{phase: :monitoring}}
    end
  end

  # F181: broker failing every enqueue → simulates a POST-lock failure (pod already spawned).
  defmodule FailTaskQueue do
    def enqueue(_pod_id, _attrs), do: {:error, :broker_down}
  end

  # SLOT-FREEZE: engineer as PIPE (lifetime_scope: pipe) → the gate takes the pipe-aware path (vs one-shot).
  defmodule StubLoaderPipe do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    def load(_), do: {:error, :not_found}
  end

  # Pipe spawner CONFIGURABLE via the process dict (`:pipe_state`) — one stub for the gate's 4 states.
  # pod_info exposes conditions + has_active_task (like the real pod); reprovision_pipe_workspace traces.
  defmodule StubSpawnerPipe do
    def spawn_pod(_p, t, o) do
      send(self(), {:spawned, t, o})
      {:ok, self()}
    end

    def wake_pod(p) do
      send(self(), {:woke, p})
      :ok
    end

    def kill_pod(p) do
      send(self(), {:killed, p})
      :ok
    end

    def reprovision_pipe_workspace(p, project, opts) do
      send(self(), {:reprovisioned, p, project, opts})
      Process.get(:reprovision_result, :ok)
    end

    def pod_info(p) do
      send(self(), {:pod_info, p})

      case Process.get(:pipe_state, :dead) do
        :dead -> {:error, :not_found}
        :ready -> {:ok, %{conditions: [], has_active_task: false}}
        :busy_active -> {:ok, %{conditions: [], has_active_task: true}}
        :publishing -> {:ok, %{conditions: [:publishing], has_active_task: false}}
        # F-C059: probe that RAISES (transient failure on a LIVE-but-slow pipe) → UNKNOWN state.
        :raise -> raise "F-C059: pod_info RAISED (transient probe failure on a LIVE pipe)"
        # Contract split at the spawner: a TIMED-OUT info call is :unreachable, never :not_found.
        :unreachable -> {:error, :unreachable}
      end
    end
  end

  # F075: loader that SIGNALS every load(role) → allows asserting a SINGLE load per dispatch.
  defmodule CountingLoader do
    def load(role) do
      send(self(), {:f075_loaded, role})

      {:ok,
       %Fleet.CapProfile{
         kind: "CapabilityProfile",
         metadata: %{},
         spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
       }}
    end
  end

  defp dispatch_opts(extra \\ []) do
    Keyword.merge(
      [
        repo: "lordzurp/lcars-test",
        forge_client: StubForge,
        loader: StubLoader,
        spawner: StubSpawner,
        task_queue: StubTaskQueue,
        # Hermetic root for `Roles.project_jury` (never created): no .lcars.json →
        # the delegation default card, regardless of the REAL filesystem's state.
        code_root: Path.join(System.tmp_dir!(), "lcars-void-projects"),
        # default stub resolver: no project (ordering tests clone nothing).
        project_resolver: fn _repo, _opts -> {:ok, nil} end,
        # #5.2 D2 — default route (step build=engineer): since the decoupling, a ROUTELESS issue is
        # ONBOARDED (skip) instead of spawning. Effect tests want a spawn → they start from an
        # already-routed issue. Routed/onboard tests override `forge_opts`/`workflow_map_loader`.
        forge_opts: [_test_route: {:ok, {"g", "build"}}],
        # Generic loader (any map name): carries `max_rework_rounds` (rework budget read as data on
        # the PR AND issue rework paths). Specific routed tests override as needed.
        workflow_map_loader: fn _name ->
          %{
            "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
            "max_rework_rounds" => 2,
            # `ci` is mandatory on a real card, so a stub standing in for one declares it too.
            # Omitting it no longer means "no CI policy": `Roles.ci/1` reads an un-declared card as
            # a card that bypassed the schema and gates rather than assuming green — which is right
            # in production and would turn every dispatch test here into a CI test.
            "ci" => "ignore"
          }
        end
      ],
      extra
    )
  end

  describe "dispatch_issue/2 (effects, stubbed seams)" do
    test "F075: a single load(role) per dispatch (end of the probe+spawn double-load)" do
      payload = eng_issue()

      assert {:ok, {:spawned, _, "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(loader: CountingLoader))

      # decide loads the profile and threads it; dispatch reuses it → load called EXACTLY once.
      assert_received {:f075_loaded, "engineer"}
      refute_received {:f075_loaded, _}
    end

    test "spawn: order lock-label → pod (no more comment-lock), returns {:ok, {:spawned, pod, role}}" do
      payload = eng_issue()

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts())

      # the brief = issue.body + the git-native DELIVERY instruction (local commit + trailer),
      # otherwise the pod "submits the contents" instead of committing → :no_deliverable_commit.
      assert_received {:spawned, "issue-42", opts}
      assert opts[:brief] =~ "fais le hello"

      # pod-seed: RC Desktop name = <project>#<ticket>_<role> (project = final segment of the repo
      # "lordzurp/lcars-test"). Exact label, distinct from the technical pod_id. With one eng per
      # ticket, the project alone no longer distinguishes two live pods of the same role — the
      # number is what the human reads to tell them apart in the Desktop list.
      assert opts[:rc_name] == "lcars-test#42_engineer"

      # …and the slug travels ALONGSIDE the label, never re-parsed out of it (see `project_slug`
      # below): that is what keeps the label free to change shape.
      assert opts[:project_slug] == "lcars-test"
      assert opts[:brief] =~ "git commit"

      # AUCUN trailer dans l'ordre de mission (2026-08-05). Il est pose MECANIQUEMENT par le hook
      # `prepare-commit-msg` installe au clone, donc le pod n'a aucune action a prendre dessus — et
      # ce sur quoi il n'a pas d'action n'a pas a exister dans son monde. L'ordre le DEMANDAIT (un
      # run de producteur refait le jour ou une ligne a atterri au milieu du message), puis l'a
      # brievement ANNONCE, ce qui etait la meme faute un cran plus discret.
      refute opts[:brief] =~ "Co-authored-by"

      # The eng's voice (outgoing info): the brief asks for a `summary` posted on the PR by the system.
      assert opts[:brief] =~ "summary"
      assert opts[:brief] =~ "Ta voix"
      # Blocked_dep: the brief tells the eng to mark `blocked: true` rather than guess/wedge.
      assert opts[:brief] =~ "blocked"

      # the brief is ENQUEUED in the TaskQueue (otherwise the pod thinks it's bootstrap → idle;
      # PASSE-9 bug)
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", attrs}
      assert attrs.brief =~ "fais le hello"
      assert attrs.role == "engineer"

      # F071: locks the 2nd `IssueId.compose` site (enqueue_brief) — otherwise a return to the
      # literal "issue-#{number}" for `issue_id` would not be caught (pod_id ≠ issue_id).
      assert attrs.issue_id == "issue-42"
      # kick emitted — a failed wake would not be silent: spawn_step returns
      # `{:error, {:wake_unreached, …}}` (counted as errors by the poller, re-wake next tick).
      assert_received {:woke, "lordzurp-lcars-test-engineer"}
    end

    test "CI-01: draining → dispatch_issue = {:skipped, :draining}, NO spawn, NO lock (gate is the flag, not a block)" do
      payload = eng_issue()

      # Drain in progress (`quiescing?` seam true): dispatch_issue opens NO new producer — it skips BEFORE
      # decide/spawn → no `lcars-in-flight` label, no pod. The issue stays assigned+unlocked on the forge.
      assert {:skipped, :draining} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(quiescing?: fn -> true end))

      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}

      # NOT draining (seam explicitly false → hermetic, independent of the global flag): the SAME issue
      # dispatches normally → the gate is the drain flag, never a blanket block.
      assert {:ok, {:spawned, _pod, "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(quiescing?: fn -> false end))

      assert_received {:spawned, _, _}
    end

    test "GATE slot_scope: engineer (project) already alive → DEFERS :role_busy (serialized, no rebrief)" do
      payload = eng_issue()

      # StubSpawnerAlive: pod_info → {:ok,_} = the project pod `<repo>-engineer` is ALREADY alive
      # (another issue of the repo in progress). The gate serializes project-scoped roles: we DEFER,
      # we do NOT rebrief a busy pod (that would wedge — a one-shot mid-task does not pull a 2nd
      # brief). The poller re-dispatches next tick; the pod dies at end of task → fresh spawn for
      # the next one.
      assert {:skipped, :role_busy} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(spawner: StubSpawnerAlive))

      # The gate CONSULTED pod_info (with the PROJECT id) to see the live pod...
      assert_received {:pod_info, "lordzurp-lcars-test-engineer"}
      # ...then DEFERRED without ANY side effect: no spawn, no enqueue, no wake.
      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}
      refute_received {:woke, _}
    end

    test "GATE slot_scope: engineer (project) alive → defers BEFORE lock/enqueue (nothing to compensate)" do
      # The gate defers BEFORE setting the lock or enqueueing → the failing task_queue is NEVER
      # reached. So no lock to remove, no pod to kill: the deferral is side-effect free.
      assert {:skipped, :role_busy} =
               StepDispatcher.dispatch_issue(
                 eng_issue(),
                 dispatch_opts(spawner: StubSpawnerAlive, task_queue: FailTaskQueue)
               )

      refute_received {:removed_label, _}
      refute_received {:killed, _}
      refute_received {:enqueued, _, _}
    end

    test "F181: POST-lock failure (enqueue KO) → lock removed + pod killed (no stuck)" do
      payload = eng_issue()
      opts = dispatch_opts(task_queue: FailTaskQueue)

      assert {:error, {:enqueue_failed, :broker_down}} =
               StepDispatcher.dispatch_issue(payload, opts)

      # the pod had spawned → killed (otherwise orphan); the lcars-in-flight lock → removed
      # (otherwise the poller would skip the issue forever).
      assert_received {:spawned, "issue-42", _}
      assert_received {:killed, "lordzurp-lcars-test-engineer"}
      assert_received {:removed_label, "lcars-in-flight"}
    end

    test "CI-10: POST-lock failure + remove_label FAILS → honest 'lock removal FAILED' log, never the 'lock removed' lie" do
      payload = eng_issue()

      opts =
        dispatch_opts(
          task_queue: FailTaskQueue,
          forge_opts: [
            _test_route: {:ok, {"g", "build"}},
            _test_remove_label: {:error, :forge_down}
          ]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:enqueue_failed, :broker_down}} =
                   StepDispatcher.dispatch_issue(payload, opts)
        end)

      # The compensation ATTEMPTED the removal (message sent) but it FAILED → the log names the FACT
      # (issue stays in-flight, reconciliation reclaims). Scoped to THIS pod (bleed-proof, capture_log is
      # global); NEVER the pre-CI-10 flat "lock removed" for this pod.
      assert_received {:removed_label, "lcars-in-flight"}
      assert log =~ ~r/pod=lordzurp-lcars-test-engineer.*lock removal FAILED/
      refute log =~ ~r/pod=lordzurp-lcars-test-engineer.*\(lock removed/
    end

    # MA-17 — escalated wake (unreachable pod, re-wake KO → {:error,{:escalated,_}}). A discarded
    # WakeRecovery.wake return (`_ = wake(...)`) → dispatch_issue returned {:ok,{:spawned}} → the
    # poller counted a LYING `dispatched:1/errors:0` (pod never woken). The `wake_recovery` seam
    # simulates the escalation; we assert the dispatch is NOT a silent success but
    # `{:error,{:wake_unreached,_}}`.
    test "MA-17: escalated wake (unreachable pod) → dispatch {:error,{:wake_unreached}}, NOT {:ok,{:spawned}}" do
      payload = eng_issue()

      # Seam: the wake recovery ESCALATES (equivalent to re-wake KO → starfleet). No real
      # IncidentRegistry/forge hits — we inject the unreachability verdict directly.
      escalating_wake = fn _pod_id, _respawn, _opts -> {:error, {:escalated, :dead}} end

      result =
        StepDispatcher.dispatch_issue(
          payload,
          dispatch_opts(wake_recovery: escalating_wake)
        )

      # THE finding: above all NOT a silent dispatch success (the poller counted it dispatched:1).
      refute match?({:ok, {:spawned, _, _}}, result)

      assert {:error,
              {:wake_unreached, "lordzurp-lcars-test-engineer", "engineer", {:escalated, :dead}}} =
               result

      # The pod AND the brief STAY in place (brief enqueued, re-wake/escalation covers): NO
      # compensation (this is not a post-lock failure, it is an unreachable wake). The lock holds.
      assert_received {:spawned, "issue-42", _}
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", _}
      refute_received {:removed_label, _}
      refute_received {:killed, _}
    end

    # MA-17 — counter-proof: a CLEAN wake (:ok) keeps the dispatch a `{:ok,{:spawned}}` success
    # (the `dispatched` tally stays honest when the pod IS really woken).
    test "MA-17: wake OK → dispatch stays {:ok,{:spawned}} (honest dispatched tally)" do
      payload = eng_issue()
      clean_wake = fn _pod_id, _respawn, _opts -> :ok end

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(wake_recovery: clean_wake))

      refute_received {:removed_label, _}
      refute_received {:killed, _}
    end

    test "skip in_flight: no spawn" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}]})

      assert {:skipped, :in_flight} = StepDispatcher.dispatch_issue(payload, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "the step's FACE reaches the resolver as :base_branch — and its absence means code (THE default site)" do
      # chantier face-projet: the card step is the ONLY place the face is decided. `face: ops` →
      # the resolver is asked for ops; no face → main. Downstream nobody re-defaults (the
      # resolver raises without :base_branch — its own test) : this is the one site, so this test
      # is the one that guards the default.
      payload = eng_issue()
      me = self()

      capturing_resolver = fn _repo, r_opts ->
        send(me, {:resolver_base, Keyword.get(r_opts, :base_branch)})
        {:ok, nil}
      end

      ops_loader = fn _name ->
        %{
          # role engineer ON PURPOSE: the face belongs to the STEP, not the role (a card may put
          # any producer on any face) — and the StubLoader only knows the canon test roles.
          "steps" => %{"build" => %{"role" => "engineer", "face" => "ops", "needs" => []}},
          "max_rework_rounds" => 2
        }
      end

      opts = dispatch_opts(project_resolver: capturing_resolver, workflow_map_loader: ops_loader)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:resolver_base, "ops"}

      # Face-less step (every pre-existing card) → the code face, decided here and only here.
      opts2 = dispatch_opts(project_resolver: capturing_resolver)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts2)
      assert_received {:resolver_base, "main"}
    end

    test "a ticket carrying a LOT clones from the lot, and its PR still lands on the FACE" do
      # The lot is the MATTER (docs, a directory, images) published as `lcars/lot-<slug>`. Two bases
      # that coincide on every other ticket separate here, and only here: the pod CLONES the lot,
      # and its PR LANDS on the face. The deliverable gate keeps the lot as its base — its question
      # is "does base..HEAD hold the pod's work and nothing else", and the pod started at the lot.
      sha = String.duplicate("ab", 20)
      me = self()

      payload =
        eng_issue(%{
          "body" => "traite le paquet\n\nLot: lcars/lot-morse-ui-v2 @ #{sha}"
        })

      capturing_resolver = fn _repo, r_opts ->
        send(
          me,
          {:bases, Keyword.get(r_opts, :base_branch), Keyword.get(r_opts, :gate_base_branch)}
        )

        {:ok, %{"base_sha" => sha}}
      end

      opts = dispatch_opts(project_resolver: capturing_resolver)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)

      # The clone base moves to the lot; the GATE base is left alone (it defaults to the clone
      # base — pointing it at the face would run the identity and co-author checks over the
      # MATTER commits, which the producer never made).
      assert_received {:bases, "lcars/lot-morse-ui-v2", nil}

      # And the lot is a STARTING POINT, not a destination: the PR base is named explicitly,
      # otherwise the completer opens it on the clone base and the work merges into the matter.
      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:project]["pr_base_branch"] == "main"
    end

    test "an ordinary ticket names NO gate base — the lot rail costs the common path nothing" do
      me = self()

      capturing_resolver = fn _repo, r_opts ->
        send(
          me,
          {:bases, Keyword.get(r_opts, :base_branch), Keyword.get(r_opts, :gate_base_branch)}
        )

        {:ok, nil}
      end

      opts = dispatch_opts(project_resolver: capturing_resolver)
      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(eng_issue(), opts)
      assert_received {:bases, "main", nil}
    end

    test "a lot pointer with an out-of-scheme ref STOPS the dispatch, never falls back to the face" do
      # The fallback is the failure worth preventing: a producer starting from the head of its face
      # and working against matter it never saw, with nothing saying so.
      payload = eng_issue(%{"body" => "Lot: refs/heads/evil @ #{String.duplicate("ab", 20)}"})

      opts = dispatch_opts(project_resolver: fn _repo, _o -> {:ok, nil} end)

      assert {:error, {:lot_pointer, {:invalid_lot_ref, "refs/heads/evil"}}} =
               StepDispatcher.dispatch_issue(payload, opts)
    end

    test "a lot branch that MOVED since the ticket was written → refused, the pinned sha is an anchor" do
      # Re-publishing under a lot name already used moves the branch. Without this comparison the
      # older ticket would dispatch onto the newer matter, differing only by a sha nobody reads.
      pinned = String.duplicate("ab", 20)
      moved = String.duplicate("cd", 20)
      payload = eng_issue(%{"body" => "Lot: lcars/lot-paquet-3 @ #{pinned}"})

      opts = dispatch_opts(project_resolver: fn _repo, _o -> {:ok, %{"base_sha" => moved}} end)

      assert {:error, {:lot_moved, {"lcars/lot-paquet-3", ^pinned, ^moved}}} =
               StepDispatcher.dispatch_issue(payload, opts)
    end

    test "resolved project → injected into spawn_opts (:project, F-03 pinned base_sha)" do
      payload = eng_issue()

      project = %{
        "repo_path" => "http://10.42.0.118/lordzurp/lcars-test.git",
        "base_branch" => "main",
        "base_sha" => "cafe1234"
      }

      opts = dispatch_opts(project_resolver: fn _repo, _opts -> {:ok, project} end)

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:project] == project
      assert spawn_opts[:brief] =~ "fais le hello"
    end

    test "recorded route → role derived from the workflow_map (step build=engineer) + pipeline/step injected (A2.1, #8)" do
      payload = eng_issue()

      # #8: the role NOW comes from the workflow_map (WorkflowMapNav.step_role), not a hardcoded
      # producer_role. Here the current step "build" carries role=engineer → engineer role (and
      # route injected, A2.1).
      workflow_map = %{
        "name" => "poc-cycle",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"poc-cycle", "build"}}],
          workflow_map_loader: fn "poc-cycle" -> workflow_map end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:workflow_map] == "poc-cycle"
      assert spawn_opts[:step] == "build"
    end

    test "#8: route on an UPSTREAM step (brief-review/consultant) → spawns the CONSULTANT, not the eng" do
      payload = eng_issue()

      # The workflow_map IS the state machine: the 1st step (root `needs:[]`) is
      # brief-review/consultant. decide() returned "engineer" (DN §1); workflow_map_role overrides
      # with the current step's role → consultant.
      workflow_map = %{
        "name" => "brief-gate",
        "steps" => %{
          "brief-review" => %{"role" => "consultant", "needs" => []},
          "build" => %{"role" => "engineer", "needs" => ["brief-review"]}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"brief-gate", "brief-review"}}],
          workflow_map_loader: fn "brief-gate" -> workflow_map end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-consultant", "consultant"}} =
               StepDispatcher.dispatch_issue(payload, opts)
    end

    test "#8.B: brief_kind:judge AT THE STEP overrides a worker profile (engineer) → JUDGE brief" do
      payload = eng_issue()

      # The step declares brief_kind:judge; the engineer role has a WORKER profile. The per-step
      # override must produce a JUDGE brief (defused), NOT the worker brief (issue body +
      # "Livraison git-native").
      workflow_map = %{
        "name" => "g",
        "steps" => %{
          "review" => %{"role" => "engineer", "needs" => [], "brief_kind" => "judge"}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:spawned, "issue-42", spawn_opts}
      refute spawn_opts[:brief] =~ "Livraison (git-native)"
    end

    test "#8.B: without brief_kind at the step → profile default (engineer=worker → worker brief)" do
      payload = eng_issue()

      workflow_map = %{
        "name" => "g",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "build"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:spawned, "issue-42", spawn_opts}
      # "Livraison (git-native)" pins the FR user-facing brief section heading.
      assert spawn_opts[:brief] =~ "Livraison (git-native)"
    end

    test "SECURITY: out-of-vocab brief_kind at the step → raise (never silently falls back to worker)" do
      payload = eng_issue()

      # `reviewer` is NOT part of the {worker, judge} vocabulary. Falling back to the `_worker`
      # clause would produce an EXECUTABLE brief for a role that should have been defused.
      # Judge-ness is a security property: it is not inferred by omission → fail-loud.
      workflow_map = %{
        "name" => "g",
        "steps" => %{
          "review" => %{"role" => "engineer", "needs" => [], "brief_kind" => "reviewer"}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert_raise ArgumentError, ~r/out of vocabulary \{worker, judge\}/, fn ->
        StepDispatcher.dispatch_issue(payload, opts)
      end
    end

    test "SECURITY: out-of-vocab judge_target (kind=judge) → raise (a judge's target is not inferred)" do
      payload = eng_issue()

      workflow_map = %{
        "name" => "g",
        "steps" => %{
          "review" => %{
            "role" => "engineer",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "subject"
          }
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert_raise ArgumentError, ~r/out of vocabulary \{brief, deliverable\}/, fn ->
        StepDispatcher.dispatch_issue(payload, opts)
      end
    end

    test "#8.E: judge_target:brief → brief in BRIEF framing (judges the issue.body, not a deliverable)" do
      # F-S2-1: the brief = the ISSUE body at hand (payload), NOT a redundant get_issue.
      payload = eng_issue(%{"body" => "MON BRIEF A JUGER"})

      workflow_map = %{
        "name" => "mg",
        "steps" => %{
          "brief-review" => %{
            "role" => "consultant",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "brief"
          }
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"mg", "brief-review"}}],
          workflow_map_loader: fn "mg" -> workflow_map end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-consultant", "consultant"}} =
               StepDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      brief = spawn_opts[:brief]
      # BRIEF framing (subject:brief) + the brief to judge, NOT the deliverable framing.
      assert brief =~ "Brief to judge"
      assert brief =~ "MON BRIEF A JUGER"
      refute brief =~ "Deliverable to judge (step outputs"
      refute brief =~ "Livraison (git-native)"
    end

    test "#5.2 D2 — ROUTELESS issue → onboarded onto the default workflow_map (skip), NO eng spawn" do
      payload = eng_issue()

      # route :none (overrides the default route) + default workflow_map brief-gate (1st step
      # brief-review).
      opts =
        dispatch_opts(
          forge_opts: [_test_route: :none],
          workflow_map_loader: fn "brief-gate" ->
            %{"steps" => %{"brief-review" => %{"role" => "consultant", "needs" => []}}}
          end
        )

      assert {:skipped, :onboarded} = StepDispatcher.dispatch_issue(payload, opts)

      # the default workflow_map was RECORDED (next tick will dispatch the consultant); NO eng spawn.
      assert_received {:routed, 42, "brief-gate", "brief-review"}
      refute_received {:spawned, _, _}
    end

    test "ROUTELESS issue with `genre/doc` → onboarded onto the OPS card, not the project's (chantier face-projet)" do
      # The destination gate of the burn: the label is the INPUT, the engraved wfmap/* the OUTPUT — read
      # once, here. A face-projet mutation that drops the gate re-routes ops tickets down the code
      # path silently; this is the test that falls.
      payload = eng_issue(%{"labels" => [%{"name" => "destination/workshop"}]})

      opts =
        dispatch_opts(
          forge_opts: [_test_route: :none],
          workflow_map_loader: fn "workshop-direct" ->
            %{"steps" => %{"build" => %{"role" => "engineer", "face" => "ops", "needs" => []}}}
          end
        )

      assert {:skipped, :onboarded} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:routed, 42, "workshop-direct", "build"}
      refute_received {:spawned, _, _}
    end

    test "route read failure → {:error, {:route_resolution, _}}, NO lock nor spawn" do
      payload = eng_issue()
      opts = dispatch_opts(forge_opts: [_test_route: {:error, :http_500}])

      assert {:error, {:route_resolution, :http_500}} =
               StepDispatcher.dispatch_issue(payload, opts)

      refute_received {:spawned, _, _}
    end

    test "project resolution failure → {:error}, NO lock set nor spawn" do
      payload = eng_issue()

      opts =
        dispatch_opts(project_resolver: fn _repo, _opts -> {:error, :ls_remote_timeout} end)

      assert {:error, {:project_resolution, :ls_remote_timeout}} =
               StepDispatcher.dispatch_issue(payload, opts)

      # resolution BEFORE any forge write: no spawn, no orphan lock
      refute_received {:spawned, _, _}
    end

    # ====================================================================
    # SLOT-FREEZE — PIPE-aware gate: a PIPE engineer (resident) is re-briefed by its state.
    #   dead  -> fresh spawn; busy (active task OR :publishing) -> DEFERS; ready -> COLD
    #   reprovision + rebrief. (project["base_sha"] is passed at reset; the slug = the issue's
    #   feature branch.)
    # ====================================================================
    test "GATE pipe DEAD (1st issue): fresh spawn, NO reprovision" do
      Process.put(:pipe_state, :dead)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(eng_issue(), opts)

      assert_received {:spawned, "issue-42", _opts}
      refute_received {:reprovisioned, _, _, _}
    end

    test "GATE pipe BUSY (active task): DEFERS :role_busy, neither reprovision nor spawn (pod mid-work)" do
      Process.put(:pipe_state, :busy_active)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe PUBLISHING (deliverable in flight): DEFERS :role_busy (no reset during the push)" do
      Process.put(:pipe_state, :publishing)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe READY (idle + deliverable confirmed): COLD reprovision (base_sha + slug) THEN re-brief" do
      Process.put(:pipe_state, :ready)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(eng_issue(), opts)

      # cold reset called BEFORE the rebrief, with the project (base_sha) + the issue's slug.
      assert_received {:reprovisioned, "lordzurp-lcars-test-engineer",
                       %{"base_sha" => "basesha1"}, [slug: _slug]}

      # re-brief (live pod) -> enqueue + wake, NO fresh re-spawn.
      refute_received {:spawned, _, _}
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", _}
      assert_received {:woke, "lordzurp-lcars-test-engineer"}
    end

    test "GATE pipe READY but reset KO -> DEFERS :role_busy (no rebrief on a dirty workspace)" do
      Process.put(:pipe_state, :ready)
      Process.put(:reprovision_result, {:error, {:reset_failed, :git_exit}})

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      assert_received {:reprovisioned, _, _, _}
      refute_received {:enqueued, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe pod_info RAISES (transient probe failure on a LIVE pipe): DEFERS :role_busy, NO destructive spawn (F-C059)" do
      # F-C059: a pod_info raise left the state UNKNOWN → :error → :dead → serialize `:ok` → fresh
      # spawn that REAPS/kills the LIVE eng pipe + its context (the exact danger `pod_alive?`
      # guards with "assume ALIVE"). Fail-closed: uncertainty (raise) → DEFERS (mirror of
      # pod_alive?), never reset/kill.
      Process.put(:pipe_state, :raise)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe pod_info UNREACHABLE (info call timed out, pod maybe ALIVE): DEFERS :role_busy, NO destructive spawn" do
      # The spawner's contract split: a live-but-slow pod whose info call times out is
      # :unreachable — the old flattening into :not_found read it as DEAD → fresh spawn on
      # the deterministic id → reap of the LIVING pipe eng + its context. Fail-closed like
      # the RAISE case: defer, never reset/kill.
      Process.put(:pipe_state, :unreachable)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end
  end

  describe "dispatch_review/2 (PR-driven judge)" do
    defp pr(fields \\ %{}) do
      Map.merge(
        %{
          "number" => 6,
          "head" => %{"ref" => "lcars/issue-42-engineer"},
          "requested_reviewers" => [%{"login" => "Qualifier"}],
          "labels" => []
        },
        fields
      )
    end

    test "PR with review requested -> spawns the judge (issue=ISSUE, lock on the PR)" do
      opts =
        dispatch_opts(
          forge_opts: [
            _test_route: {:ok, {"poc", "spec-review"}},
            _test_issue_body: "implémente le décodeur morse"
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-qualifier", "qualifier"}} =
               StepDispatcher.dispatch_review(pr(), opts)

      # issue_id = the ISSUE (derived from head.ref lcars/issue-42-engineer), NOT the PR
      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:workflow_map] == "poc" and spawn_opts[:step] == "spec-review"
      # defused judge brief (brief_kind: judge) — not an executable body
      assert spawn_opts[:brief] =~ "JUDGE"

      # Info-starvation fix (judge): empty predecessor (git-native) → the judge is POINTED at its
      # workspace AND receives the CRITERION (issue body, defused in context).
      # The diff base is `origin/main` (single-branch clone: the local ref `main` does not exist —
      # live morse bug: `git diff main..HEAD` → fatal unknown revision → intermittent
      # halt_wait_input).
      assert spawn_opts[:brief] =~ "git diff origin/main...HEAD"
      assert spawn_opts[:brief] =~ "implémente le décodeur morse"

      # enqueue targets the pr-... pod_id; issue_id = the issue
      assert_received {:enqueued, "lordzurp-lcars-test-pr-6-qualifier", attrs}
      assert attrs.issue_id == "issue-42"
      assert attrs.role == "qualifier"
      assert_received {:woke, "lordzurp-lcars-test-pr-6-qualifier"}
    end

    test "locked PR (lcars-in-flight) -> skip, no spawn" do
      pr = pr(%{"labels" => [%{"name" => "lcars-in-flight"}]})
      assert {:skipped, :in_flight} = StepDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "PR without judge (orphan/human) -> ADOPTION: sets the judges, review next tick" do
      pr = pr(%{"requested_reviewers" => []})

      # requested == [] (neither requested_reviewers nor jury) = PR NOT set up by the pipeline
      # (typically human/fork discovered by the poller). Agent-agnostic gate → we SET the judges
      # instead of skipping `:no_verdict`. They spawn on the NEXT tick (not here →
      # `refute_received {:spawned}`).
      assert {:ok, {:adopted, _pr_number, reviewers}} =
               StepDispatcher.dispatch_review(pr, dispatch_opts())

      assert reviewers != []
      assert_received {:requested_review, _index, ^reviewers}
      refute_received {:spawned, _, _}
    end

    test "ZERO-JUDGE card (jury []) + no requested judge → NOMINAL sealed merge, NOT adoption" do
      # The card arbitrates the no-judge case: an empty jury makes `requested == []` the
      # nominal path → straight to the sealed merge (provenance wall inside seal_and_merge);
      # no judge laid, no judge spawned. `reviewer_roles: []` = the card's jury via the seam.
      pr = pr(%{"requested_reviewers" => [], "number" => 6})

      assert {:ok, {:merged, 6}} =
               StepDispatcher.dispatch_review(pr, dispatch_opts(reviewer_roles: []))

      assert_received {:merged, 6}
      refute_received {:requested_review, _, _}
      refute_received {:spawned, _, _}
    end

    test "②.1d: all requested judges APPROVED -> PROMOTE (closing comment + FF merge, gatekeeper)" do
      # both requested judges each have a decisive APPROVED verdict → empty pending → all green → merge.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [_test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved}]
        )

      assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)

      # the FF merge was triggered on the PR (explicit close via seal_and_merge, no more Closes #N)
      assert_received {:merged, 6}
      refute_received {:spawned, _, _}

      # Die-on-promote: the kill-site targets `for_issue` (id `...-issue-42-engineer`). For the
      # one-shot project-scoped eng this is a PHANTOM pod_id → SAFE no-op (cf. step_dispatcher:
      # using for_repo here would kill the eng if it were coding ANOTHER issue). We assert the kill
      # CALL with the issue-keyed id (even if it no-ops), unconditional on the dispatcher side.
      assert_received {:killed, "lordzurp-lcars-test-issue-42-engineer"}

      # REGRESSION guard: this path (poller-driven merge, no-workflow_map) NEVER lifted the ISSUE
      # lock — only the PR lock lifted (via each judge's route(:reviewed), out-of-scope here).
      # `promote_pr` must now also lift the ISSUE (42): the entire brick is done at merge.
      assert_received {:stopped_watch, 42}
    end

    test "CI-08: promote unlock FAILS → honest 'issue lock NOT released' log (never the lie) + retry, still {:ok, {:merged}}" do
      # The merge/seal/close all succeed; only the TERMINAL issue unlock (remove_label) fails. The
      # promote genuinely succeeded → the return stays {:ok, {:merged}}, but the log must follow the
      # VERDICT (CI-08 — "le caller ne doit pas annoncer le retrait avant son verdict"): never the
      # blanket "issue lock released" lie, and the retrait is retried (last-chance: the closed issue is
      # no longer re-polled) before being surfaced LOUD.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_remove_label: {:error, :forge_down}
          ]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)
        end)

      # The merge happened — the promote succeeded despite the unlock failure.
      assert_received {:merged, 6}

      # Verdict-following honest log (bleed-proof: scoped to THIS test's issue #42 + the new phrase).
      assert log =~ "issue=#42 MERGED+SEALED+CLOSED but issue lock NOT released"
      # The bounded retry was attempted (last-chance reconciliation).
      assert log =~ "issue #42 unlock attempt 1/3 FAILED"
      # The old blanket lie must NOT appear on the failure path.
      refute log =~ "eng killed, issue lock released"
    end

    # JG-063 — « warden/manual cleanup » DESIGNAIT UN RAIL QUI N'EXISTE PAS. Verifie : les deux
    # `warden` du depot portent sur les PODS, aucun ne retire d'etiquette de forge ; et le poller ne
    # lit que `list_open_issues/2`, donc cette issue FERMEE n'est plus jamais vue. La phrase
    # promettait un rattrapage automatique imaginaire, et « manual » suppose qu'un humain lise ce
    # log — ce que la doctrine D1 refuse pour tout ce qui est load-bearing.
    #
    # Le residu n'est pas benin : l'etiquette suggere un travail en cours qui n'existe pas, et le
    # chronometre fausse definitivement les metriques de duree de ce ticket.
    test "JG-063: un verrou residuel ouvre un INCIDENT durable, et le log ne promet plus de rail" do
      test = self()

      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          escalate_fun: fn kind, subject, cause, sig, _o ->
            send(test, {:escalated, kind, subject, cause, sig})
            {:ok, 1}
          end,
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_remove_label: {:error, :forge_down}
          ]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)
        end)

      assert_received {:escalated, :issue_lock_residual, _subject, {:unlock_failed, _}, _sig},
                      "le verrou residuel n'a laisse qu'un log : rien de durable ne le dit"

      refute log =~ "warden/manual cleanup",
             "le log promet toujours un rail de rattrapage qui n'existe pas"

      assert log =~ "the cleanup is MANUAL: no rail reclaims it"
    end

    test "F-C061: a NON-jury login (human) among the reviewers is filtered (does not starve the jury) + LOUD" do
      # A human (`Lordzurp`) reviews/is-requested on the PR (read suffices — verified live, the
      # forge does NOT prevent it). WITHOUT the filter: they have no verdict → `hd(pending)` =
      # lordzurp → `RoleDispatch.load_role_or_skip` fails → SILENT `{:skipped, :no_role}` → the
      # jury (qualifier + reviewer, all APPROVED) is STARVED, no merge. WITH the `reviewer_roles`
      # filter: lordzurp excluded from the jury → all judges approved → merge, and the non-jury
      # reviewer is signaled LOUD (not swallowed).
      pr =
        pr(%{
          "requested_reviewers" => [
            %{"login" => "Qualifier"},
            %{"login" => "Reviewer"},
            %{"login" => "Lordzurp"}
          ],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [_test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved}]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # behavior: the non-jury human login does not starve the merge.
          assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)
        end)

      # LOUD: the non-jury reviewer is signaled (F-C061), not silently absorbed.
      assert log =~ "F-C061" and log =~ "lordzurp"
      # never dispatched as a role.
      refute_received {:spawned, _, "lordzurp"}
    end

    test "F-C061: a REQUEST_CHANGES from a NON-jury login (human) does NOT trigger a stray rework" do
      # 2nd vector of the same hole: a human POSTS a verdict (not just requested) → they enter
      # `verdicts` AND the jury (REQUEST_CHANGES review-record). WITHOUT the filter:
      # `Map.take(verdicts, requested)` includes lordzurp → STRAY `dispatch_rework` (rework cycle
      # triggered by a human). WITH the `reviewer_roles` filter: lordzurp excluded from `requested`
      # → their voice does not count → the jury (qualifier + reviewer, approved) → merge. Human
      # login signaled LOUD.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_reviewers: ["qualifier", "reviewer", "lordzurp"],
            _test_verdicts: %{
              "qualifier" => :approved,
              "reviewer" => :approved,
              "lordzurp" => :changes_requested
            }
          ]
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # the human REQUEST_CHANGES is IGNORED (no rework) → all-approved jury → merge.
          assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)
        end)

      assert log =~ "F-C061" and log =~ "lordzurp"
      refute_received {:spawned, _, "reviewer"}
    end

    # ── The "machine reads the full forge state" angle: merge failure CLASSIFIED ──
    # Replaces the old catch-all "any failure = conflict → eng rebase" (impossible because
    # forge-blind → live dead end). The failure is re-read from the PR object (MergeOutcome) and
    # routed to its REAL cause.

    test "merge failure + REAL git conflict, budget available → producer CONFLICT-REWORK (tier 1), no escalation" do
      # Tier 1 (fleet/hello#3 retex 2026-07-19): the producer resolves ON its PR — bounded by
      # max_rework_rounds, counted via the [conflict-rework:pr-N markers posted by this path.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_route: {:ok, {"g", "build"}},
            _test_merge_result: {:error, {:http, 409, "conflict"}},
            _test_conflict_rounds: {:ok, 0},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => false
            }
          ]
        )

      assert {:ok, _} = StepDispatcher.dispatch_review(pr, opts)

      # The PRODUCER is (re)spawned on its brick — the conflict is production work, not arbitrage.
      assert_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "merge failure + REAL conflict, budget EXHAUSTED → honest arch escalation (tier 3)" do
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 409, "conflict"}},
            _test_route: {:ok, {"g", "build"}},
            # rounds ≥ budget (2, default loader) → no more automatic rework.
            _test_conflict_rounds: {:ok, 2},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => false
            }
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "merge failure + PR mergeable:true (POLICY: human re-request) → re-dispatches the re-requested judge" do
      # THE hello-kitty case: git-mergeable, but branch-protection refuses (a judge manually
      # re-requested reset the approvals counter). We re-dispatch that judge (the button finally
      # does its job), NO escalation, NO conflict treatment.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6,
          "head" => %{"ref" => "lcars/issue-42-engineer"}
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "Does not have enough approvals"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: ["qualifier"]
          ]
        )

      assert {:ok, {:spawned, _pod, "qualifier"}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:merged, _}
    end

    test "merge failure + PR mergeable:true WITHOUT re-request → honest escalation (unliftable policy, no silent wedge)" do
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: []
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
    end

    test "merge blocked by a RED CI → PRODUCER rework, not a human (the rung, 2026-08-03)" do
      # Measured on a live bench: a PR whose head carried `CI / ci (push)` = failure was PROMOTED —
      # nothing in the runtime read a commit status and the forge rule had `enable_status_check:
      # false`. Requiring the check closes the merge door; this test holds the other half, without
      # which the fix would only trade a silent promotion for a silent wedge.
      #
      # A red CI is not a human matter and does not re-converge: nothing changes until the producer
      # pushes a new commit. Sending it to the arch — which is what `{:policy, :no_rerequest}` did,
      # naming the absence of a re-request rather than the actual cause — summons a human for work
      # only the engineer can do.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: [],
            _test_ci: :failure
          ]
        )

      # NOT `{:merge_blocked_escalated, _}` — that is the arch, and this is the producer's.
      refute match?(
               {:skipped, {:merge_blocked_escalated, 6}},
               StepDispatcher.dispatch_review(pr, opts)
             )
    end

    test "merge blocked while the CI is still PENDING → the next tick asks again, nobody is summoned" do
      # A rail that has not finished is not a verdict. Escalating here would page a human for the
      # duration of every CI run, and dispatching rework would ask the producer to fix nothing.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: [],
            _test_ci: :pending
          ]
        )

      assert {:skipped, :ci_pending} = StepDispatcher.dispatch_review(pr, opts)
    end

    test "…mais une carte `ci: ignore` ne doit PAS attendre la CI, meme sur ce chemin" do
      # LA JOINTURE QUI MANQUAIT, mesuree de bout en bout sur un banc le 2026-08-10.
      #
      # `CiGate.decide/4` consulte la politique de la carte avant de gater. La RECONVERGENCE, elle,
      # lisait `commit_ci_state` inconditionnellement et rendait `{:skipped, :ci_pending}` sur
      # `:pending` — donc `wait/ci`. Deux sites, une seule question, un seul des deux ecoutait la
      # reponse.
      #
      # Vecu : un catalogue dont la carte declare `ci: ignore`, un deploiement sans runner. Le
      # producteur livre, la PR est mergeable, le jury est vide — donc on arrive ici — et le ticket
      # prend `wait/ci` pour toujours, alors que sa carte promettait de ne pas dependre d'une CI.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          workflow_map_loader: fn _name ->
            %{
              "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
              "max_rework_rounds" => 2,
              "ci" => "ignore"
            }
          end,
          forge_opts: [
            _test_route: {:ok, {"g", "build"}},
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: [],
            _test_ci: :pending
          ]
        )

      refute match?({:skipped, :ci_pending}, StepDispatcher.dispatch_review(pr, opts)),
             "une carte `ci: ignore` ne doit jamais produire wait/ci — la CI n'est pas ce qui bloque"
    end

    # Les deux seams de conflit (`:conflict_diagnoser` / `:conflict_applier`) existaient sans qu'un
    # seul test ne les injecte — une indirection dont le benefice, l'hermetisme, n'etait jamais
    # consomme (BL-6-42.2). Et la mesure a montre pire que « une seam inutilisee » : `tier0_decision`
    # (le routage PUR) etait deja teste, mais le CABLAGE — flag → diagnoser → decision → acte —
    # n'avait aucun test. Le trou tombait exactement entre une fonction prouvee et le monde, soit
    # la portion que ces seams existent pour rendre testable.
    # Les deux sondes rendent la forme REELLE d'un diagnostic (`files` + `totals`), pas seulement
    # les totaux que le routage consomme. Un fake qui rend une forme de seam inexistante n'affaiblit
    # pas un test, il l'INVERSE : celui-ci passait vert alors que le rendu du rapport, ajoute le
    # 2026-08-05, ne pouvait pas s'executer sur cette forme.
    defmodule AllSemanticProbe do
      def probe(_repo, _ref, _opts) do
        {:ok,
         %{
           files: %{
             "lib/a.ex" => %{
               hunks: [
                 %Fleet.Conflict.Hunk{
                   base_lines: [],
                   ours_lines: ["a"],
                   theirs_lines: ["b"],
                   start_line: 12,
                   type: :complex,
                   confidence: %Fleet.Conflict.ConfidenceScore{score: 10, label: :low},
                   explanation: "deux intentions distinctes",
                   trace: %Fleet.Conflict.DecisionTrace{
                     selected: :complex,
                     summary: "aucun motif trivial ne s'applique",
                     has_base: false
                   },
                   zdiff3: false
                 }
               ]
             }
           },
           totals: %{none_trivial?: true, total: 1, trivial: 0, complex: 1, writable: 0}
         }}
      end
    end

    defmodule AllWritableProbe do
      def probe(_repo, _ref, _opts) do
        {:ok,
         %{
           files: %{
             "lib/b.ex" => %{
               hunks: [
                 %Fleet.Conflict.Hunk{
                   base_lines: ["x"],
                   ours_lines: ["x", "y"],
                   theirs_lines: ["x"],
                   start_line: 3,
                   type: :one_side_change,
                   confidence: %Fleet.Conflict.ConfidenceScore{score: 90, label: :high},
                   explanation: "un seul cote a bouge",
                   trace: %Fleet.Conflict.DecisionTrace{
                     selected: :one_side_change,
                     summary: "la base prouve que seul `ours` a change",
                     has_base: true
                   },
                   zdiff3: false
                 }
               ]
             }
           },
           totals: %{all_writable?: true, total: 1, trivial: 1, complex: 0, writable: 1}
         }}
      end
    end

    defmodule BlindProbe do
      def probe(_repo, _ref, _opts), do: {:error, :cannot_diagnose}
    end

    defmodule ResolvingApplier do
      def apply(_repo, _ref, _opts), do: {:ok, :auto_resolved}
    end

    defp conflict_pr,
      do:
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6,
          # `pr_base_branch` n'est PAS une option du dispatch : `step_dispatcher` l'ECRASE depuis
          # l'objet PR (`get_in(pr, ["base","ref"])`), et c'est la bonne source — la face d'un PR
          # est une propriete du PR, pas du harnais. La poser en opts ne servait a rien.
          "base" => %{"ref" => "main"}
        })

    defp conflict_opts(extra) do
      dispatch_opts(
        Keyword.merge(
          [
            forge_opts: [
              _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
              _test_merge_result: {:error, {:http, 405, "conflit"}},
              _test_pull: %{
                "number" => 6,
                "state" => "open",
                "draft" => false,
                "mergeable" => false
              }
            ]
          ],
          extra
        )
      )
    end

    # La sonde qui ne diagnostique rien : elle CAPTURE les opts qu'on lui tend. Le rendu `:error`
    # renvoie le chemin sur le legacy, dont l'observable ne discrimine rien ici — c'est voulu, ce
    # test n'assure pas le routage mais l'ARGUMENT, et l'argument n'est visible que d'ici.
    defmodule DirCapturingProbe do
      def probe(_repo, _ref, opts) do
        send(self(), {:probe_opts, opts})
        {:error, :captured}
      end
    end

    test "la FACE de la PR decide le worktree ou son conflit est resolu" do
      # Le commentaire de `conflict_face_opts/1` decrit ce defaut comme repare : les helpers
      # tombaient sur leur defaut `origin/main` DANS le worktree de la face code, et sur une PR ops
      # cela resolvait un conflit en fusionnant la face CODE dans une branche doc — silencieusement,
      # en rapportant `{:ok, :auto_resolved}`. La reparation etait la, RIEN ne la tenait : renvoyer
      # la face ops vers `projects_root` laissait les 2451 tests verts (mesure 2026-08-08). Une
      # cicatrice ecrite en commentaire et non gardee se fait retirer par le prochain refactor, qui
      # lit un `case` a trois branches identiques a deux details pres et « simplifie ».
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, DirCapturingProbe)

      name = Fleet.Layout.project_name("lordzurp/lcars-test")

      ops_pr = Map.put(conflict_pr(), "base", %{"ref" => "ops"})
      _ = StepDispatcher.dispatch_review(ops_pr, conflict_opts([]))
      assert_received {:probe_opts, ops_opts}
      assert ops_opts[:dir] == Path.join(Fleet.Layout.ops_root(), name)
      assert ops_opts[:base_branch] == "origin/ops"

      # Et le jumeau code, sans quoi l'assertion ci-dessus passerait aussi si les deux faces
      # pointaient le meme arbre.
      _ = StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
      assert_received {:probe_opts, code_opts}
      assert code_opts[:dir] == Path.join(Fleet.Layout.code_root(), name)
      assert code_opts[:base_branch] == "origin/main"
    end

    test "tier-0 : un conflit TOUT-SEMANTIQUE saute le producteur, et sans chief il atteint l'arch" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllSemanticProbe)

      # Le gain de tier-0 RACCOURCIT un chemin, il n'en casse aucun : un conflit dont rien n'est
      # trivial ne deviendra pas resoluble en y envoyant un producteur trois fois.
      #
      # Depuis le 2026-08-05 le cas va d'abord au CHIEF (L3), pas droit a l'arch (L4). Cette
      # fixture n'a pas de role `conflict_resolver` : la passe d'exception ne se dispatche pas, et
      # la ladder RETOMBE sur l'arch au lieu de laisser tomber le conflit. C'est exactement ce que
      # ce tuple prouve maintenant — pas le routage nominal, mais le fait que le dernier barreau
      # passe la main quand il ne peut pas etre grimpe.
      assert {:skipped, {:merge_blocked_escalated, 6}} =
               StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))

      # Et c'est LA le gain, pas le tuple : aucun round de producteur n'a ete brule.
      refute_received {:spawned, _issue, _opts}
    end

    test "tier-0 : un conflit TOUT-ECRIVABLE est resolu par le runtime, sans pod" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllWritableProbe)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_applier, ResolvingApplier)

      # C'est ICI que la seam `:conflict_applier` gagne sa vie : sans injection, ce chemin exige un
      # vrai worktree git et ne serait jamais exerce.
      assert {:ok, {:auto_resolved, 6}} =
               StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
    end

    # ❌ PAS de test pour la sonde MUETTE (`{:error, _}` → `:fall_through`), et la raison est
    # mesuree : dans ce harnais le chemin legacy converge sur le MEME observable que l'escalade
    # tier-0 — meme tuple de retour, et aucun spawn dans les deux cas. Un test ecrit ici
    # n'assertait rien. Le rendre discriminant demande de faire dispatcher un producteur au chemin
    # legacy, donc d'instrumenter le budget de rework du harnais : un geste de harnais, pas une
    # assertion. Non fait, plutot qu'un test vert qui ne separe rien.

    test "flag OFF : le diagnoser n'est meme pas consulte (le defaut reste le chemin legacy)" do
      # `conflict_diagnosis?` est false par defaut ; ce test epingle que le defaut ne traverse pas
      # tier-0 — sinon les trois tests ci-dessus prouveraient un chemin que la prod n'emprunte pas.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, false)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllWritableProbe)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_applier, ResolvingApplier)

      refute match?(
               {:ok, {:auto_resolved, 6}},
               StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
             )
    end

    test "PR flipped back to DRAFT (judge-dispatch guard) → skip, no review nor merge" do
      pr =
        pr(%{
          "number" => 6,
          "draft" => true,
          "requested_reviewers" => [%{"login" => "Qualifier"}]
        })

      assert {:skipped, :draft} = StepDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "②.1d: one judge requested changes (the others approve) -> re-spawns the PRODUCER" do
      # all requested judges have a verdict (empty pending), but one :changes_requested → rework.
      pr =
        pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :changes_requested},
            _test_route: {:ok, {"poc", "build"}},
            _test_feedback: [
              %{"login" => "reviewer", "body" => "le timing des points/traits est faux"}
            ]
          ]
        )

      # producer = git_native role of head (lcars/issue-42-engineer) = engineer; lock on the PR.
      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:brief] =~ "REWORK"

      # Info-starvation fix (rework): the REQUEST_CHANGES review BODY is injected (otherwise
      # "fix according to the review" is hollow → the eng guesses blindly → blocked_dep/wedge,
      # proven live morse).
      assert spawn_opts[:brief] =~ "le timing des points/traits est faux"
      assert spawn_opts[:brief] =~ "reviewer"

      # The eng's voice (rework): the brief asks for a `summary` = answer to the reviewer, posted
      # on the PR.
      assert spawn_opts[:brief] =~ "summary"
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", attrs}
      assert attrs.role == "engineer"
    end

    test "MA-06: rework UNDER budget (rounds <= max) -> producer re-spawn (no escalation)" do
      # Lower-bound guard: as long as the budget is not exhausted, rework continues normally.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_rework_rounds: {:ok, 2},
            _test_route: {:ok, {"poc", "build"}}
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)
    end

    test "frein-publish P2: publish streak > budget -> PUBLISH-BRAKE escalation, no re-spawn (the verdict counter is frozen)" do
      # The measured hole: a rework whose PUBLICATION fails produces no verdict → `rounds` freezes
      # under budget → the old brake never fires → a real producer session burned per tick,
      # unbounded (faceproof bench, 5 identical rounds). The publish streak is the counter that
      # moves — over the SAME budget, it must escalate BEFORE any re-spawn.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"g", "build"}},
            # rounds frozen at 1 (under budget 2) — exactly the loop's shape...
            _test_rework_rounds: {:ok, 1},
            # ...while the publish failures accumulated past the budget.
            _test_publish_fails: {:ok, 3}
          ]
        )

      assert {:skipped, {:publish_brake_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:spawned, _, _}
    end

    test "frein-publish P2: streak AT budget -> rework proceeds (the brake bounds, it does not preempt)" do
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:ok, 1},
            _test_publish_fails: {:ok, 2}
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)
    end

    test "frein-publish P2: unreadable publish counter -> escalation, never a blind loop" do
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:ok, 1},
            _test_publish_fails: {:error, {:http, 500, "boom"}}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:spawned, _, _}
    end

    test "MA-06: N PR rework rounds (rounds > budget) -> ARCH ESCALATION (bounded, no infinite churn)" do
      # Illegal state before MA-06: `dispatch_rework` re-spawned the producer with NO counter → if
      # the eng never satisfies the judge, INFINITE rework (the workflow_map `rebound` brake is not
      # called on this path). The fix bounds by a forge-native counter (nb REQUEST_CHANGES):
      # > budget (2) → arch escalation (no re-spawn). We verify the return
      # {:skipped, {:rework_exhausted_escalated, _}} + the awaits-arch label set.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            # Route present → the budget (= max_rework_rounds:2 of the generic loader) is READABLE:
            # we truly test "rounds(3) > budget(2) → escalation", not an unreadable budget
            # (covered by the next test).
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:ok, 3}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      # NO producer re-spawn (end of churn); the human awaits-arch lock is set on the ISSUE.
      refute_received {:spawned, _, _}
    end

    test "MA-06: unreadable budget (forge {:error}) -> escalation (no blind re-spawn)" do
      # Symmetric of `rebound`: an unverifiable budget must NOT loop → we escalate to the arch.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            # Route present → readable budget: we truly test the unreadable COUNTER (count
            # {:error}), not the route.
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:error, {:http, 500, "boom"}}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:spawned, _, _}
    end

    test "map-level PR budget HONORED: max_rework_rounds:5 bounces at 4 rounds (the default 2 would escalate)" do
      # Proof that the PR budget comes from the map's DATA (spec.max_rework_rounds), not a coded
      # default: a map at 5 lets 4 rounds bounce (4 ≤ 5) where the old default of 2 would have
      # escalated.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"budget5", "build"}},
            _test_rework_rounds: {:ok, 4}
          ],
          workflow_map_loader: fn "budget5" ->
            %{
              "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
              "max_rework_rounds" => 5
            }
          end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)
    end

    test "F-E8: judge dropped from requested_reviewers (but in the review-records) stays in the jury -> spawn, NO merge" do
      # Live bug PoC-7: Gitea made the reviewer VANISH from `requested_reviewers` WITHOUT them
      # voting (review-record still REQUEST_REVIEW). The volatile field only shows the qualifier
      # (who approved). WITHOUT the fix: requested=[qualifier], pending=[] → premature MERGE on 1
      # judge (half-jury). WITH it: the jury comes from the review-records
      # (`pr_review_state.reviewers` = [qualifier, reviewer]) → union → pending=[reviewer] → we
      # spawn the reviewer, NEVER a merge.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved},
            _test_reviewers: ["qualifier", "reviewer"],
            _test_route: {:ok, {"poc", "review"}},
            _test_issue_body: "implémente le décodeur morse"
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-reviewer", "reviewer"}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:merged, _}
    end

    test "PR on a non-fleet branch -> skip (never misrouted)" do
      pr = pr(%{"head" => %{"ref" => "refs/pull/6/head"}})
      assert {:skipped, :not_fleet_branch} = StepDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "F-C061: reviewer = non-jury login (human/unknown) ALONE → filtered + LOUD, NO silent skip" do
      # Old contract (F-C061 bug): an unknown login → SILENT `{:skipped, :no_role}`. New: a
      # non-jury login (here `lordzurp`, human) is FILTERED from the jury → the PR ends up without
      # a judge → ADOPTION (we set the jury, review next tick), and the foreign login is signaled
      # LOUD (never swallowed).
      pr = pr(%{"requested_reviewers" => [%{"login" => "lordzurp"}]})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, {:adopted, _pr_number, reviewers}} =
                   StepDispatcher.dispatch_review(pr, dispatch_opts())

          assert reviewers != []
        end)

      assert log =~ "F-C061" and log =~ "lordzurp"
      refute_received {:spawned, _, "lordzurp"}
    end

    test "F181: POST-lock failure (enqueue KO) -> PR lock removed + pod killed" do
      # `_test_route: :none` means the ISSUE carries no engraved card, so the CI policy comes from
      # the PROJECT's declared card — which requires it. The green is a PREMISE of this test, not
      # its subject: it says "the CI rail is fine, the enqueue is what breaks".
      opts =
        dispatch_opts(
          task_queue: FailTaskQueue,
          forge_opts: [_test_route: :none, _test_ci: :success]
        )

      assert {:error, {:enqueue_failed, :broker_down}} =
               StepDispatcher.dispatch_review(pr(), opts)

      assert_received {:killed, "lordzurp-lcars-test-pr-6-qualifier"}
      assert_received {:removed_label, "lcars-in-flight"}
    end

    test "MA-01 (bug B): the parent issue carries awaits-arch -> skip :awaits_arch, NO judge re-dispatch" do
      # The PR head=lcars/issue-42-engineer (issue 42) has a requested reviewer → WITHOUT the fix,
      # the judge would be re-spawned every tick. But issue 42 is in the `:awaits_arch_ids` SET
      # (escalation in progress) → `dispatch_review` skips (symmetric of `decide/1` on the issue
      # side) → end of churn.
      opts = dispatch_opts(awaits_arch_ids: MapSet.new([42]))

      assert {:skipped, :awaits_arch} = StepDispatcher.dispatch_review(pr(), opts)
      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}
    end

    test "MA-01 (bug B): awaits_arch_ids does NOT contain the issue -> normal dispatch (back-compat)" do
      # Guard: the skip only triggers for the concerned issue. Issue 42 (PR head) absent from the
      # SET (here {99}) → normal judge dispatch. And default empty MapSet (other callers) →
      # unchanged.
      opts =
        dispatch_opts(
          awaits_arch_ids: MapSet.new([99]),
          forge_opts: [_test_route: {:ok, {"poc", "spec-review"}}, _test_issue_body: "x"]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-qualifier", "qualifier"}} =
               StepDispatcher.dispatch_review(pr(), opts)
    end
  end

  # F-PARALLEL-PR-CONFLICT — DECONFLATION of clone-base / gate-base. For a rebase resolution, the
  # pod starts from the feature (clone-base) but its deliverable must DESCEND from `main`
  # (gate-base) → the resolver pins BOTH separately when `:gate_base_branch` is set. Fixture: a
  # local bare repo = the "forge".
  describe "default_project_resolver/2 — deconflated gate_base_sha" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      forge = Path.join(tmp, "forge")
      src = Path.join(tmp, "src")
      File.mkdir_p!(forge)
      gg = fn args -> {_o, 0} = System.cmd("git", ["-C", src] ++ args, stderr_to_stdout: true) end

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
      gg.(["config", "user.email", "engineer@lcars.local"])
      gg.(["config", "user.name", "LCARS-engineer"])
      File.write!(Path.join(src, "base.txt"), "c0")
      gg.(["add", "."])
      gg.(["commit", "-q", "-m", "c0"])

      # feature-branch (the producer's work, from C0)
      gg.(["checkout", "-q", "-b", "lcars/issue-3-engineer"])
      File.write!(Path.join(src, "feat.txt"), "feat")
      gg.(["add", "."])
      gg.(["commit", "-q", "-m", "feat"])
      {ft, 0} = System.cmd("git", ["-C", src, "rev-parse", "HEAD"], stderr_to_stdout: true)

      # `main` advances (parallel issue merged) → C1
      gg.(["checkout", "-q", "main"])
      File.write!(Path.join(src, "para.txt"), "para")
      gg.(["add", "."])
      gg.(["commit", "-q", "-m", "c1"])
      {m1, 0} = System.cmd("git", ["-C", src, "rev-parse", "HEAD"], stderr_to_stdout: true)

      # publish both branches into the bare = `<forge>/owner/proj.git` (base_url = `<forge>`)
      bare = Path.join(forge, "owner/proj.git")
      File.mkdir_p!(Path.dirname(bare))
      {_, 0} = System.cmd("git", ["clone", "-q", "--bare", src, bare], stderr_to_stdout: true)

      %{base_url: forge, feature_tip: String.trim(ft), main_c1: String.trim(m1)}
    end

    test "resolve (gate_base_branch=main): base_sha=feature_tip (clone) BUT gate_base_sha=main",
         ctx do
      assert {:ok, proj} =
               StepDispatcher.default_project_resolver("owner/proj",
                 base_branch: "lcars/issue-3-engineer",
                 gate_base_branch: "main",
                 forge_opts: [base_url: ctx.base_url]
               )

      # clone-base = feature tip (the pod starts from ITS work); gate-base = main (rebase target).
      assert proj["base_sha"] == ctx.feature_tip
      assert proj["gate_base_sha"] == ctx.main_c1
      refute proj["base_sha"] == proj["gate_base_sha"]
    end

    test "forward (without gate_base_branch): gate_base_sha == base_sha (clone-base, unchanged)",
         ctx do
      assert {:ok, proj} =
               StepDispatcher.default_project_resolver("owner/proj",
                 base_branch: "lcars/issue-3-engineer",
                 forge_opts: [base_url: ctx.base_url]
               )

      assert proj["base_sha"] == ctx.feature_tip
      assert proj["gate_base_sha"] == proj["base_sha"]
    end

    test "gate_base_branch EGAL a base_branch : une seule lecture, pas deux (BL-6-40 ampli 3)",
         ctx do
      # Le chemin forward passe `gate_base_branch == base_branch` — le moduledoc dit qu'elles
      # coincident. On payait quand meme une SECONDE `ls-remote` (reseau, bornee a 15 s, DANS le
      # GenServer du poller) pour une valeur deja en main.
      #
      # Ce que ce test tient n'est PAS le compte d'appels (invisible d'ici) mais sa CONSEQUENCE
      # observable : les deux shas sont issus de la MEME lecture, donc rigoureusement egaux. Deux
      # `ls-remote` sur le meme ref a deux instants peuvent diverger si quelqu'un pousse entre les
      # deux — le pod clonerait une base et serait juge contre une autre, sans qu'aucune des deux
      # ne soit fausse. La reutilisation est donc plus CONSISTANTE, pas seulement plus rapide.
      assert {:ok, proj} =
               StepDispatcher.default_project_resolver("owner/proj",
                 base_branch: "main",
                 gate_base_branch: "main",
                 forge_opts: [base_url: ctx.base_url]
               )

      assert proj["base_sha"] == ctx.main_c1
      assert proj["gate_base_sha"] == proj["base_sha"]
    end
  end
end
