defmodule Fleet.Pilot.StepRunConsumerGateTest do
  @moduledoc """
  Exercises gate-driven completion and evaluation resumption through the real consumer/completer
  with stubbed forge, publication and pod operations. Failures consume a signed-run budget
  before rebound or architect escalation; soft gates enqueue evaluations.
  Native PR and issue-level brief verdicts remain distinct. Selected tests collect ordered
  messages or defer closures; ordinary selective receives prove only presence.
  """
  use ExUnit.Case, async: true
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Pilot.CompletionOutbox
  alias Fleet.Pilot.StepRunConsumer
  alias Fleet.Pilot.StepRunConsumer.Verdict
  alias Fleet.Pilot.StubTaskQueue

  # Forge spy; the injected counter is fixed and does not increment when a marker posts.
  defmodule StubForge do
    # No jury verdicts in this fixture.
    def get_route(_r, _n, _o), do: :none

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    # Fail only the gate-fail marker, so an unsigned run cannot rebound under budget.
    def post_comment(_r, _n, body, o) do
      if body =~ "gate-fail" and Keyword.get(o, :_sign_fails, false) do
        {:error, :forge_write_down}
      else
        send(self(), {:comment, body})
        {:ok, :posted}
      end
    end

    def set_assignee(_r, _n, login, _o) do
      send(self(), {:assignee, login})
      {:ok, :set}
    end

    def remove_label(_r, _n, _l, _o) do
      send(self(), :unlocked)
      {:ok, :removed}
    end

    def add_label(_r, _n, label, _o) do
      send(self(), {:label, label})
      {:ok, :added}
    end

    # Capture closure kind to distinguish delivery from abandonment.
    def close_issue(_r, _n, o) do
      send(self(), {:closed, Keyword.get(o, :closure)})
      {:ok, :closed}
    end

    # Observe the stopwatch call as well as label removal; no real timer state is tested.
    def stop_stopwatch(_r, _n, _o) do
      send(self(), :stopwatch_stopped)
      :ok
    end

    def count_signed_step_runs(_r, _n, opts), do: {:ok, Keyword.get(opts, :_step_runs, 0)}

    def post_route(_r, _n, p, s, _o) do
      send(self(), {:route, p, s})
      {:ok, :posted}
    end

    def open_pr(_r, head, base, _t, o) do
      send(self(), {:open_pr, head, base, o[:body]})
      {:ok, 7}
    end

    def get_pr_for_branch(_r, head, base, _o) do
      send(self(), {:get_pr, head, base})
      {:ok, 7}
    end

    # Brief judges run before a producer PR exists.
    def list_open_pulls(_r, _o), do: {:ok, []}

    def request_review(_r, pr, revs, _o) do
      send(self(), {:request_review, pr, revs})
      :ok
    end

    def post_review(_r, pr, ev, body, _o) do
      send(self(), {:review, pr, ev, body})
      :ok
    end

    def merge_pr(_r, pr, _o) do
      send(self(), {:merge, pr})
      :ok
    end

    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
  end

  defmodule DelivStub do
    def publish(o) do
      send(self(), {:publish, o})
      {:ok, %{commit_sha: "sha-x", pushed?: true, mode: Map.get(o, :mode, :git_native)}}
    end
  end

  defmodule StubSpawner do
    def wake_pod(pod_id) do
      send(self(), {:wake, pod_id})
      :ok
    end

    def notify_pod(pod_id, message) do
      send(self(), {:notify, pod_id, message})
      :ok
    end

    def spawn_pod(_cap, pod_id, opts) do
      send(self(), {:spawned, pod_id, opts})
      {:ok, self()}
    end
  end

  defmodule FailSpawner do
    def wake_pod(pod_id) do
      send(self(), {:wake, pod_id})
      :ok
    end

    def spawn_pod(_cap, _pod_id, _opts), do: {:error, :launch_failed}
  end

  # Two-step cards vary gate type and budget.
  defmodule WorkflowMap do
    def load!("gated") do
      %{
        "name" => "gated",
        "max_rework_rounds" => 2,
        "steps" => %{
          "build" => %{
            "role" => "engineer",
            "needs" => [],
            "gate" => %{"type" => "hard", "rules" => ["ok"]}
          },
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    # Nondefault budget 4 gives total 2 * (4 + 1) = 10.
    def load!("gated4") do
      %{
        "name" => "gated4",
        "max_rework_rounds" => 4,
        "steps" => %{
          "build" => %{
            "role" => "engineer",
            "needs" => [],
            "gate" => %{"type" => "hard", "rules" => ["ok"]}
          },
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    def load!("soft") do
      %{
        "name" => "soft",
        "max_rework_rounds" => 2,
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => [], "gate" => %{"type" => "soft"}},
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    def load!("plain") do
      %{
        "name" => "plain",
        "max_rework_rounds" => 2,
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    def load!("mandgate") do
      %{
        "name" => "mandgate",
        "max_rework_rounds" => 2,
        "steps" => %{
          "brief-review" => %{
            "role" => "scoper",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "brief"
          },
          "build" => %{"role" => "engineer", "needs" => ["brief-review"]}
        }
      }
    end

    # Omit judge kind on the card to distinguish the payload's effective stamp.
    def load!("mandnodeclare") do
      %{
        "name" => "mandnodeclare",
        "max_rework_rounds" => 2,
        "steps" => %{
          "brief-review" => %{"role" => "scoper", "needs" => []},
          "build" => %{"role" => "engineer", "needs" => ["brief-review"]}
        }
      }
    end

    # A gatekeeper continue on a terminal producer must enter review, not merge without judges.
    def load!("softterm") do
      %{
        "name" => "softterm",
        "max_rework_rounds" => 2,
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => [], "gate" => %{"type" => "soft"}}
        }
      }
    end

    # Human approval routes directly to architect action rather than spending rework rounds.
    def load!("humanapp") do
      %{
        "name" => "humanapp",
        "max_rework_rounds" => 2,
        "steps" => %{
          "build" => %{
            "role" => "engineer",
            "needs" => [],
            "gate" => %{"type" => "terminal", "human_approval_required" => true}
          }
        }
      }
    end
  end

  defmodule FailingCloseCompleter do
    def complete(_step_run, _opts), do: {:error, :close_boom}
  end

  defp dmode,
    do: fn
      "engineer", _root -> {:ok, "git_native"}
      _, _root -> {:ok, "payload"}
    end

  defp hc(opts \\ []) do
    %StepRunConsumer{
      repo: "o/r",
      remote: "origin",
      forge_opts: Keyword.get(opts, :forge_opts, []),
      role_emails: fn r -> ["#{r}@lcars.local"] end,
      step_run_completer: Fleet.Pilot.StepRunCompleter,
      forge_client: StubForge,
      loader: WorkflowMap,
      deliverable: DelivStub,
      deliverable_mode_fun: Keyword.get(opts, :deliverable_mode_fun, dmode()),
      task_queue: StubTaskQueue,
      spawner: Keyword.get(opts, :spawner, StubSpawner),
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      gate_evals: %{}
    }
  end

  defp build_done(workflow_map_name, result) do
    %{
      "issue_id" => "issue-1",
      "workspace" => "/ws",
      "base_sha" => "cafe",
      "base_branch" => "main",
      "role" => "engineer",
      "workflow_map" => workflow_map_name,
      "step" => "build",
      "result" => result
    }
  end

  defp soft_ctx do
    %{
      n: 1,
      role: "engineer",
      payload: build_done("soft", %{"x" => 1}),
      workflow_map: WorkflowMap.load!("soft"),
      step: "build"
    }
  end

  test "gate :pass -> producer :advance: opens the PR, request_review(reviewer), records the route" do
    assert {:ok, :review_requested} =
             StepRunConsumer.maybe_complete(build_done("gated", %{"ok" => true}), hc())

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}

    refute_received {:assignee, _}
    assert_received {:route, "gated", "review"}

    # Producer advance retains the issue lock through review.
    refute_received :unlocked
  end

  test "producer/judge classification consumes the EFFECTIVE payload mode, not a since-spawn re-derivation" do
    # A supplied effective mode must win over a resolver reporting a different mode.
    payload = Map.put(build_done("gated", %{"ok" => true}), "deliverable_mode", "git_native")
    drifted = hc(deliverable_mode_fun: fn _role, _root -> {:ok, "payload"} end)

    assert {:ok, :review_requested} = StepRunConsumer.maybe_complete(payload, drifted)

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}
  end

  test "no gate on the step -> advance (unchanged behavior)" do
    assert {:ok, :review_requested} =
             StepRunConsumer.maybe_complete(build_done("plain", %{}), hc())

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}
    refute_received {:assignee, _}
    assert_received {:route, "plain", "review"}
  end

  test "gate {:fail} under budget -> producer bounce (engineer), NO PR" do
    payload = build_done("gated", %{})

    assert {:ok, :rework_requested} =
             StepRunConsumer.maybe_complete(payload, hc(forge_opts: [_step_runs: 0]))

    # Rebound changes route and unlocks; it does not use assignee-based dispatch.
    refute_received {:assignee, _}
    assert_received {:route, "gated", "build"}
    assert_received :unlocked
    refute_received {:open_pr, _, _, _}
  end

  test "gate {:fail} + budget exhausted -> ESCALATION await_arch (end of G2 churn), no more log-only {:error}" do
    # At 6 runs, the two-step budget 2 * (2 + 1) is exhausted; inspect architect effects.
    payload = build_done("gated", %{})

    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(payload, hc(forge_opts: [_step_runs: 6]))

    assert_received {:label, "lcars-awaits-arch"}

    # awaits-arch excludes worker dispatch; unlock also ends in-flight ownership.
    assert_received :unlocked

    assert_received :stopwatch_stopped
    # These same-shape comment receives consume the failure trace before the architect trace.
    assert_received {:comment, fail_trace}
    assert fail_trace =~ "gate-fail"
    assert_received {:comment, body}
    assert body =~ "Rework"
    assert body =~ "Architecte"
    # Observe offer and wake; the escalate_user test below compares their order.
    assert_received {:enqueued, "architect-r", _}
    assert_received {:wake, "architect-r"}

    refute_received {:open_pr, _, _, _}
    refute_received {:closed, _}
  end

  test "gate {:fail} but the failed-run SIGNATURE post fails -> ESCALATION, not an unbudgeted bounce" do
    # A failed marker write must refuse rebound even with the counter below budget.
    payload = build_done("gated", %{})

    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(
               payload,
               hc(forge_opts: [_step_runs: 0, _sign_fails: true])
             )

    refute_received {:route, "gated", "build"}
    refute_received {:open_pr, _, _, _}

    assert_received {:label, "lcars-awaits-arch"}
    assert_received :unlocked
    assert_received {:comment, body}
    assert body =~ "non comptabilisé"
    assert body =~ "Architecte"
    assert_received {:enqueued, "architect-r", _}
    assert_received {:wake, "architect-r"}
  end

  test "terminal human_approval gate -> DIRECT ESCALATION await_arch (D2, no 6 wasted rework rounds)" do
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(build_done("humanapp", %{}), hc())

    assert_received {:label, "lcars-awaits-arch"}
    assert_received :unlocked
    assert_received {:comment, body}

    assert body =~ "Aval humain"
    assert body =~ "Architecte"

    assert_received {:enqueued, "architect-r", _}
    assert_received {:wake, "architect-r"}

    refute_received {:open_pr, _, _, _}
  end

  test "budget: just under the limit bounces, right at the limit ESCALATES (await_arch, no more churn)" do
    payload = build_done("gated", %{})

    assert {:ok, :rework_requested} =
             StepRunConsumer.maybe_complete(payload, hc(forge_opts: [_step_runs: 5]))

    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(payload, hc(forge_opts: [_step_runs: 6]))
  end

  test "map-level budget HONORED: gated4(max_rework_rounds:4) bounces where gated(2) escalates" do
    # A nondefault card budget distinguishes map data from a hardcoded round limit.
    payload = build_done("gated4", %{})

    assert {:ok, :rework_requested} =
             StepRunConsumer.maybe_complete(payload, hc(forge_opts: [_step_runs: 6]))

    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(payload, hc(forge_opts: [_step_runs: 10]))
  end

  test "ordinary producer step_run -> git_native deliverable (the pod committed) pushed at PR opening" do
    assert {:ok, :review_requested} =
             StepRunConsumer.maybe_complete(build_done("plain", %{}), hc())

    assert_received {:publish, d}
    assert d.mode == :git_native
    refute Map.has_key?(d, :files)
  end

  test "soft gate -> ESCALATION: brief enqueued THEN one-shot gatekeeper SPAWNED (offer-then-spawn)" do
    assert {:escalate, "corr-1", ctx} =
             StepRunConsumer.maybe_complete(build_done("soft", %{"sev" => "high"}), hc())

    assert ctx.step == "build"
    assert ctx.role == "engineer"

    # Drain in order: selective receives for different shapes would not prove enqueue precedes spawn.
    trace = drain_mailbox()

    i_enq = Enum.find_index(trace, &match?({:enqueued, "o-r-issue-1-gatekeeper", _}, &1))
    i_spawn = Enum.find_index(trace, &match?({:spawned, "o-r-issue-1-gatekeeper", _}, &1))

    assert i_enq, "aucune mise en file du brief : #{inspect(trace)}"
    assert i_spawn, "aucun spawn du gatekeeper : #{inspect(trace)}"

    assert i_enq < i_spawn,
           "le pod est SPAWNE avant que son brief soit en file — il tirera une file vide et " <>
             "s'eteindra : #{inspect(trace)}"

    # The target identity is issue-keyed; no actual one-shot pod is launched.
    {:enqueued, _, attrs} = Enum.at(trace, i_enq)
    assert attrs.role == "gatekeeper"
    assert attrs.metadata["gate_eval"] == true
    assert attrs.metadata["step"] == "build"
    assert is_binary(attrs.brief)
    assert attrs.metadata["outputs"] == %{"sev" => "high"}

    # Check spawn arguments, not boot kick or successful pull.
    {:spawned, _, spawn_opts} = Enum.at(trace, i_spawn)
    assert spawn_opts[:repo] == "o/r"
    assert is_binary(spawn_opts[:brief])

    refute Enum.any?(trace, &match?({:assignee, _}, &1)), inspect(trace)
    refute Enum.any?(trace, &match?({:open_pr, _, _, _}, &1)), inspect(trace)
    refute Enum.any?(trace, &(&1 == :unlocked)), inspect(trace)
  end

  # Preserve arrival order for sequence assertions with disjoint message shapes.
  defp drain_mailbox(acc \\ []) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # An escalation removes its original completion entry; context moves to RAM/broker metadata.
  # This test observes removal, not durability across broker/BEAM loss.
  test "escalation through handle_info: the completion is NOT kept owed in the outbox" do
    wi = "wi-esc-#{System.unique_integer([:positive])}"

    event =
      Fleet.Event.new(:spawner, :"pod.completed",
        payload:
          build_done("soft", %{"sev" => "high"})
          |> Map.put("work_item_id", wi)
          |> Map.put("pod_id", "pod-esc")
      )

    # First prove the payload is journalable, so absence after handling is meaningful.
    assert {:ok, _} = CompletionOutbox.put(event.payload)
    assert Enum.any?(CompletionOutbox.pending(), &(&1["work_item_id"] == wi))

    assert {:noreply, _} = StepRunConsumer.handle_info(event, hc())
    assert_received {:enqueued, "o-r-issue-1-gatekeeper", _}

    refute Enum.any?(CompletionOutbox.pending(), &(&1["work_item_id"] == wi)),
           "an escalated completion is acknowledged in the journal, by choice"
  end

  test "escalation: gatekeeper already ALIVE (previous eval closing) → enqueue + wake, no double spawn" do
    defmodule AliveSpawner do
      def wake_pod(pod_id), do: send(self(), {:wake, pod_id}) && :ok
      def spawn_pod(_cap, _pod_id, _opts), do: {:error, {:already_started, self()}}
    end

    assert {:escalate, "corr-1", _ctx} =
             StepRunConsumer.maybe_complete(
               build_done("soft", %{"sev" => "high"}),
               hc(spawner: AliveSpawner)
             )

    assert_received {:enqueued, "o-r-issue-1-gatekeeper", _attrs}
    assert_received {:wake, "o-r-issue-1-gatekeeper"}
  end

  test "escalation: gatekeeper already ALIVE but the WAKE fails → recovery SURFACED, not a silent :ok" do
    # Check invocation and error propagation of injected WakeRecovery; it does not call
    # the supplied wake/respawn callbacks, so their behavior is not exercised here.
    defmodule AlreadyAliveFailingWake do
      def wake_pod(pod_id), do: send(self(), {:wake, pod_id}) && {:error, :tmux_gone}
      def spawn_pod(_cap, _pod_id, _opts), do: {:error, {:already_started, self()}}
    end

    recovery = fn pod_id, _respawn, _opts ->
      send(self(), {:recovery_called, pod_id})
      {:error, {:escalated, :tmux_gone}}
    end

    assert {:error, {:gatekeeper_dispatch, {:gatekeeper_spawn, {:escalated, :tmux_gone}}}} =
             StepRunConsumer.maybe_complete(
               build_done("soft", %{"sev" => "high"}),
               hc(spawner: AlreadyAliveFailingWake, wake_recovery: recovery)
             )

    assert_received {:recovery_called, "o-r-issue-1-gatekeeper"}
  end

  test "escalation: ENVELOPED outputs %{status,result} -> unwrapped before the brief (#2)" do
    enveloped = %{"status" => "ok", "result" => %{"sev" => "low"}}

    assert {:escalate, "corr-1", _ctx} =
             StepRunConsumer.maybe_complete(build_done("soft", enveloped), hc())

    assert_received {:enqueued, _pod, attrs}
    assert attrs.metadata["outputs"] == %{"sev" => "low"}
  end

  test "escalation: gatekeeper SPAWN fails -> fail-loud (never a silent judge-less stall)" do
    # A returned spawn error propagates; no cleanup or subsequent recovery is tested.
    state = hc(spawner: FailSpawner)

    assert {:error, {:gatekeeper_dispatch, {:gatekeeper_spawn, :launch_failed}}} =
             StepRunConsumer.maybe_complete(build_done("soft", %{}), state)

    refute_received {:assignee, _}
    refute_received :unlocked
  end

  # Continue uses PR completion; its trace is carried but not posted there as a signed comment.
  # Abandon/await use the issue-level trace path.

  test "continue verdict -> producer :advance (opens PR + request_review + route)" do
    assert {:ok, :review_requested} =
             StepRunConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "continue", "reason" => "all clear"}},
               hc()
             )

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}
    refute_received {:assignee, _}
    assert_received {:route, "soft", "review"}
    assert_received {:publish, d}
    assert d.mode == :git_native

    refute_received :unlocked
  end

  test "ENVELOPED continue verdict %{status,result} -> unwrapped (gate_result), advances" do
    raw = %{
      result: %{
        "status" => "ok",
        "result" => %{"decision" => "continue", "reason" => "criterion satisfied"}
      }
    }

    assert {:ok, :review_requested} = StepRunConsumer.resume_gate(soft_ctx(), raw, hc())
    assert_received {:route, "soft", "review"}
  end

  test "abandon verdict -> close (terminal §5), NO business push (work rejected)" do
    assert {:ok, :completed} =
             StepRunConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "abandon", "reason" => "unrecoverable work"}},
               hc()
             )

    # Abandonment must not become delivered/merged evidence for dependent work.
    assert_received {:closed, :retired}
    refute_received {:publish, _}
    refute_received {:assignee, _}

    # Terminal notification carries content rather than merely waking the architect.
    assert_received {:notify, "architect-r", notice}
    assert notice =~ "ABANDONNÉ"
    refute_received {:wake, "architect-r"}
    assert_received {:comment, abody}
    assert abody =~ "Architecte"
  end

  test "abandon under OFFLOAD: the arch is kicked AFTER the close reached the forge, never before" do
    # Hold the closure to verify no notification before execution, then run it explicitly.
    # No Task concurrency or real forge persistence is measured.
    deferring = fn exec, _meta ->
      send(self(), {:deferred, exec})
      {:ok, :offloaded}
    end

    assert {:ok, :offloaded} =
             StepRunConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "abandon", "reason" => "unrecoverable work"}},
               %{hc() | step_run_runner: deferring}
             )

    refute_received {:notify, "architect-r", _}
    refute_received {:closed, _}

    assert_received {:deferred, exec}
    assert {:ok, :completed} = exec.()
    assert_received {:closed, :retired}
    assert_received {:notify, "architect-r", notice}
    assert notice =~ "ABANDONNÉ"
  end

  test "abandon under OFFLOAD: a close that FAILS kicks nobody — the forge holds no such fact" do
    deferring = fn exec, _meta ->
      send(self(), {:deferred, exec})
      {:ok, :offloaded}
    end

    assert {:ok, :offloaded} =
             StepRunConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "abandon", "reason" => "unrecoverable work"}},
               %{hc() | step_run_runner: deferring, step_run_completer: FailingCloseCompleter}
             )

    assert_received {:deferred, exec}
    assert {:error, :close_boom} = exec.()
    refute_received {:notify, "architect-r", _}
  end

  @tag :tmp_dir
  @tag :requires_git
  test "a verdict is PINNED on the project's ops face (`gate-verdicts/`) when the face exists",
       %{tmp_dir: tmp} do
    # Real local ops Git repo, no remote: verify pin commit/content, not successful push.
    work_dir = Path.join(tmp, "r")
    File.mkdir_p!(work_dir)
    {_, 0} = System.cmd("git", ["init", "-q", work_dir])
    {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.email", "t@lcars.local"])
    {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.name", "t"])

    # Exceed the pinning threshold; a short trace would leave this path untested.
    reason = Enum.map_join(1..40, "\n", &"critère #{&1} tenu, mesuré sur la brique")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :review_requested} =
                 StepRunConsumer.resume_gate(
                   soft_ctx(),
                   %{"result" => %{"decision" => "continue", "reason" => reason}},
                   %{hc() | ops_root: tmp}
                 )
      end)

    ref = Fleet.Layout.gate_verdict_ref(1, "engineer")
    refute log =~ "NOT committed", "written but not committed is a residue, not a pin"
    {sha, 0} = System.cmd("git", ["-C", work_dir, "log", "--format=%H", "-1", "--", ref])
    refute String.trim(sha) == "", "the verdict must be COMMITTED (addressable) at #{ref}"
    assert File.read!(Path.join(work_dir, ref)) =~ "critère 40 tenu"
  end

  test "escalate_user verdict -> await_arch (lcars-awaits-arch + unlock, no close/reassign) + arch KICK" do
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.resume_gate(
               soft_ctx(),
               %{
                 "result" => %{"decision" => "escalate_user", "reason" => "beyond the gatekeeper"}
               },
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
    assert_received :unlocked
    refute_received {:assignee, _}
    refute_received {:closed, _}
    assert_received {:comment, body}
    assert body =~ "gatekeeper"
    assert body =~ "escalate_user"

    assert body =~ "Architecte"

    # Compare mailbox positions so the mandate must precede the wake.
    {:messages, msgs} = Process.info(self(), :messages)

    enqueue_idx =
      Enum.find_index(msgs, &match?({:enqueued, "architect-r", _}, &1))

    wake_idx = Enum.find_index(msgs, &match?({:wake, "architect-r"}, &1))

    assert enqueue_idx, "expected the arch arbitration mandate to be enqueued (immediate rail)"
    assert wake_idx, "expected the immediate arch wake after the mandate enqueue"
    assert enqueue_idx < wake_idx, "offer must PRECEDE wake (signal-before-content race)"

    assert_received {:enqueued, "architect-r", attrs}
    assert attrs.brief =~ "Arbitrage requis"
  end

  test "halt_wait_input verdict -> await_arch" do
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "halt_wait_input", "reason" => "missing info"}},
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
  end

  test "F-C161: valid verdict WITHOUT a non-empty reason → halt_invalid (fail-closed, no approval without justification)" do
    # Known decision alone is insufficient: reason must be a nonempty string.
    assert "continue" ==
             Verdict.gate_decision(%{
               "decision" => "continue",
               "reason" => "criterion ok"
             })

    assert "halt_invalid" ==
             Verdict.gate_decision(%{"decision" => "continue"})

    assert "halt_invalid" ==
             Verdict.gate_decision(%{
               "decision" => "continue",
               "reason" => ""
             })

    # With correction disabled by loaded config, missing reason routes to await_arch.
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "continue"}},
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
  end

  test "wire envelope EXECUTED at the frontier: mistyped details/chain → halt_invalid, logged" do
    # Validate optional envelope field types as well as the required decision/reason.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert "halt_invalid" ==
                 Verdict.gate_decision(%{
                   "decision" => "continue",
                   "reason" => "criterion ok",
                   "details" => "oops",
                   "chain" => "oops"
                 })

        assert "halt_invalid" ==
                 Verdict.gate_decision(%{
                   "decision" => "continue",
                   "reason" => "criterion ok",
                   "chain" => [%{"step" => "reading"}, 42]
                 })
      end)

    assert log =~ "envelope invalid"

    assert "continue" ==
             Verdict.gate_decision(%{
               "decision" => "continue",
               "reason" => "criterion ok",
               "details" => %{"critere" => "ok"},
               "chain" => ["read", "checked"]
             })

    # With correction disabled, invalid schema routes to await_arch.
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, :awaiting_arch} =
               StepRunConsumer.resume_gate(
                 soft_ctx(),
                 %{"result" => %{"decision" => "continue", "reason" => "ok", "chain" => "oops"}},
                 hc()
               )
    end)

    assert_received {:label, "lcars-awaits-arch"}
  end

  test "redirect verdict -> await_arch (deferred A2.x, no off-DAG routing)" do
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "redirect"}},
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
    refute_received {:assignee, _}
  end

  test "absent/invalid verdict -> await_arch (fail-closed, never a silent continue)" do
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.resume_gate(soft_ctx(), %{"result" => %{}}, hc())

    assert_received {:label, "lcars-awaits-arch"}
    refute_received {:assignee, _}
    refute_received {:closed, _}
    assert_received {:comment, body}

    assert body =~ "illisible ou absent"
  end

  # Resumed continue and direct gate pass share terminal intent rules but use distinct entry paths.

  defp softterm_ctx do
    %{
      n: 1,
      role: "engineer",
      payload: %{
        "issue_id" => "issue-1",
        "workspace" => "/ws",
        "base_sha" => "cafe",
        "base_branch" => "main",
        "role" => "engineer",
        "workflow_map" => "softterm",
        "step" => "build",
        "result" => %{"sev" => "high"}
      },
      workflow_map: WorkflowMap.load!("softterm"),
      step: "build"
    }
  end

  test "MA-12: continue verdict on a TERMINAL producer → :review (opens PR + request_review), NEVER merge" do
    assert {:ok, :review_requested} =
             StepRunConsumer.resume_gate(
               softterm_ctx(),
               %{"result" => %{"decision" => "continue", "reason" => "all clear"}},
               hc()
             )

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, _revs}

    refute_received {:merge, _}
  end

  # Brief judges advance at issue level before PR creation; traces name the actual judge.

  defp brief_done(result),
    do: %{
      "issue_id" => "issue-1",
      "workspace" => "/ws",
      "base_sha" => "cafe",
      "base_branch" => "main",
      "role" => "scoper",
      "workflow_map" => "mandgate",
      "step" => "brief-review",
      "result" => result
    }

  test "#8.E brief-review continue -> ISSUE-LEVEL advance to build (route+comment, NO PR, assignee intact)" do
    assert {:ok, :reassigned} =
             StepRunConsumer.maybe_complete(
               brief_done(%{"decision" => "continue", "reason" => "clear brief"}),
               hc()
             )

    assert_received {:route, "mandgate", "build"}
    refute_received {:open_pr, _, _, _}
    refute_received {:assignee, _}
    assert_received :unlocked

    assert_received {:comment, body}
    assert body =~ "scoper"
    assert body =~ "continue"
  end

  test "#8.E brief-review escalate_user -> await_arch (arch); SCOPER trace, not gatekeeper" do
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(
               brief_done(%{"decision" => "escalate_user", "reason" => "ambiguous brief"}),
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
    assert_received :unlocked
    refute_received {:assignee, _}
    refute_received {:closed, _}
    assert_received {:comment, body}
    assert body =~ "scoper"
    refute body =~ "gatekeeper"
  end

  test "#8.E brief-review abandon -> close (brief discarded), NO PR nor push" do
    assert {:ok, :completed} =
             StepRunConsumer.maybe_complete(
               brief_done(%{"decision" => "abandon", "reason" => "brief discarded"}),
               hc()
             )

    assert_received {:closed, _}
    refute_received {:open_pr, _, _, _}
    refute_received {:publish, _}
  end

  test "BL-6-20: a STAMPED judge payload routes as a judge even when the card declares NOTHING" do
    payload =
      brief_done(%{"decision" => "escalate_user", "reason" => "ambiguous brief"})
      |> Map.merge(%{"workflow_map" => "mandnodeclare", "brief_kind" => "judge"})

    assert {:ok, :awaiting_arch} = StepRunConsumer.maybe_complete(payload, hc())
    assert_received {:label, "lcars-awaits-arch"}
  end

  test "BL-6-20: WITHOUT the stamp, an undeclared card keeps the exact legacy routing (no judge)" do
    payload =
      brief_done(%{"decision" => "escalate_user", "reason" => "ambiguous brief"})
      |> Map.put("workflow_map", "mandnodeclare")

    # Without stamp or card judge kind, this pre-PR payload takes a PR lookup dead end.
    # Preserve that existing behavior rather than interpreting it as successful review.
    assert {:error, {:pr_lookup, :no_producer_branch}} =
             StepRunConsumer.maybe_complete(payload, hc())

    refute_received {:label, "lcars-awaits-arch"}
  end

  test "BL-6-20: the stamp WINS over the step declaration (the effective fact travels)" do
    # Worker stamp wins over judge declaration; this does not verify the stamp's origin.
    payload =
      brief_done(%{"decision" => "escalate_user", "reason" => "not a verdict"})
      |> Map.put("brief_kind", "worker")

    assert {:error, {:pr_lookup, :no_producer_branch}} =
             StepRunConsumer.maybe_complete(payload, hc())

    refute_received {:label, "lcars-awaits-arch"}
  end

  test "terminal producer (build, last step of the workflow_map) -> :review (PR + judges), NEVER :promote/merge" do
    # Direct terminal producer pass enters review; subsequent PR-state sealing is not exercised.
    assert {:ok, :review_requested} =
             StepRunConsumer.maybe_complete(build_done("mandgate", %{}), hc())

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["qualifier", "reviewer"]}
    refute_received {:merge, _}
  end

  test "GenServer: soft pod.completed -> gate_evals stores; correlated work_item.completed -> pop" do
    {:ok, pid} =
      StepRunConsumer.start_link(
        # Unique GenServer names avoid collisions between async tests.
        name: :"step_run_gate_#{System.unique_integer([:positive])}",
        repo: "o/r",
        remote: "origin",
        subscribe: false,
        forge_client: StubForge,
        loader: WorkflowMap,
        deliverable: DelivStub,
        deliverable_mode_fun: dmode(),
        task_queue: StubTaskQueue,
        spawner: StubSpawner,
        role_emails: fn r -> ["#{r}@lcars.local"] end
      )

    send(pid, Fleet.Event.new(:spawner, :"pod.completed", payload: build_done("soft", %{})))

    state = settle(pid)
    assert Map.has_key?(state.gate_evals, "corr-1")
    assert %{step: "build"} = state.gate_evals["corr-1"]

    send(
      pid,
      Fleet.Event.new(:task_queue, :"work_item.completed",
        correlation_id: "corr-1",
        payload: %{result: %{"decision" => "continue"}}
      )
    )

    assert %{gate_evals: evals} = settle(pid)
    refute Map.has_key?(evals, "corr-1")
  end

  test "GenServer: correlated work_item.cleared -> eval context RELEASED (end of the singleton RAM leak)" do
    # A cleared evaluation releases its RAM payload/card without waiting for a verdict.
    # Late metadata-based resumption is exercised separately.
    {:ok, pid} =
      StepRunConsumer.start_link(
        name: :"step_run_gate_#{System.unique_integer([:positive])}",
        repo: "o/r",
        remote: "origin",
        subscribe: false,
        forge_client: StubForge,
        loader: WorkflowMap,
        deliverable: DelivStub,
        deliverable_mode_fun: dmode(),
        task_queue: StubTaskQueue,
        spawner: StubSpawner,
        role_emails: fn r -> ["#{r}@lcars.local"] end
      )

    send(pid, Fleet.Event.new(:spawner, :"pod.completed", payload: build_done("soft", %{})))
    assert Map.has_key?(settle(pid).gate_evals, "corr-1")

    send(
      pid,
      Fleet.Event.new(:task_queue, :"work_item.cleared",
        correlation_id: "corr-1",
        payload: %{work_item_id: "corr-1", reason: :superseded}
      )
    )

    assert %{gate_evals: evals} = settle(pid)
    refute Map.has_key?(evals, "corr-1")
  end

  test "GenServer: TTL sweep -> an eval context without verdict expires (backstop of the lossy rail)" do
    # TTL bounds dated contexts even when no clear event arrives; trigger it manually.
    {:ok, pid} =
      StepRunConsumer.start_link(
        name: :"step_run_gate_#{System.unique_integer([:positive])}",
        repo: "o/r",
        remote: "origin",
        subscribe: false,
        forge_client: StubForge,
        loader: WorkflowMap,
        deliverable: DelivStub,
        deliverable_mode_fun: dmode(),
        task_queue: StubTaskQueue,
        spawner: StubSpawner,
        role_emails: fn r -> ["#{r}@lcars.local"] end,
        gate_eval_ttl_ms: 0,
        # Long automatic cadence; send a sweep and settle rather than sleep/race a timer.
        gate_eval_sweep_ms: 60_000
      )

    send(pid, Fleet.Event.new(:spawner, :"pod.completed", payload: build_done("soft", %{})))
    assert Map.has_key?(settle(pid).gate_evals, "corr-1")

    send(pid, :sweep_gate_evals)

    assert %{gate_evals: evals} = settle(pid)
    refute Map.has_key?(evals, "corr-1")
  end

  test "GenServer: work_item.completed of an unknown corr -> ignored (no crash)" do
    {:ok, pid} =
      StepRunConsumer.start_link(
        # Unique GenServer name for async isolation.
        name: :"step_run_gate_#{System.unique_integer([:positive])}",
        repo: "o/r",
        remote: "origin",
        subscribe: false,
        loader: WorkflowMap
      )

    send(
      pid,
      Fleet.Event.new(:task_queue, :"work_item.completed",
        correlation_id: "inconnu",
        # No gate-eval metadata: an unknown correlation has no resumption context.
        payload: %{result: %{"decision" => "continue"}}
      )
    )

    assert %{gate_evals: evals} = settle(pid)
    assert evals == %{}
  end

  # Rebuild context in a fresh consumer from supplied metadata; broker persistence is stubbed.

  # Recreate queued metadata directly, including the original payload and role.
  defp gate_eval_meta do
    %{
      "gate_eval" => true,
      "step" => "build",
      "workflow_map" => "soft",
      "gate" => %{"type" => "soft"},
      "outputs" => %{"sev" => "high"},
      "resume_payload" => build_done("soft", %{"sev" => "high"}),
      "resume_n" => 1,
      "resume_role" => "engineer"
    }
  end

  # Relay forge effects through test_pid because the GenServer's self is not the test.
  # DelivStub messages stay in the consumer and do not witness a real push.
  defmodule RelayForge do
    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    defp relay(opts, msg), do: send(Keyword.fetch!(opts, :test_pid), msg)
    def post_comment(_r, _n, body, o), do: relay(o, {:comment, body}) && {:ok, :posted}
    def set_assignee(_r, _n, l, o), do: relay(o, {:assignee, l}) && {:ok, :set}
    def remove_label(_r, _n, _l, o), do: relay(o, :unlocked) && {:ok, :removed}
    def add_label(_r, _n, label, o), do: relay(o, {:label, label}) && {:ok, :added}
    # Relay closure kind so delivered and retired remain distinguishable.
    def close_issue(_r, _n, o),
      do: relay(o, {:closed, Keyword.get(o, :closure)}) && {:ok, :closed}

    def stop_stopwatch(_r, _n, o), do: relay(o, :stopwatch_stopped) && :ok
    def count_signed_step_runs(_r, _n, _o), do: {:ok, 0}
    def post_route(_r, _n, p, s, o), do: relay(o, {:route, p, s}) && {:ok, :posted}
    def open_pr(_r, head, base, _t, o), do: relay(o, {:open_pr, head, base, o[:body]}) && {:ok, 7}
    def get_pr_for_branch(_r, _head, _base, _o), do: {:ok, 7}
    def list_open_pulls(_r, _o), do: {:ok, []}
    def request_review(_r, pr, revs, o), do: relay(o, {:request_review, pr, revs}) && :ok
    def post_review(_r, pr, ev, body, o), do: relay(o, {:review, pr, ev, body}) && :ok
    def merge_pr(_r, pr, o), do: relay(o, {:merge, pr}) && :ok
    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
  end

  defp fresh_step_run_consumer do
    # Publication returns stub success; observations use RelayForge.
    {:ok, pid} =
      StepRunConsumer.start_link(
        name: :"step_run_gate_#{System.unique_integer([:positive])}",
        repo: "o/r",
        remote: "origin",
        subscribe: false,
        forge_opts: [test_pid: self()],
        forge_client: RelayForge,
        loader: WorkflowMap,
        deliverable: DelivStub,
        deliverable_mode_fun: dmode(),
        task_queue: StubTaskQueue,
        spawner: StubSpawner,
        role_emails: fn r -> ["#{r}@lcars.local"] end
      )

    pid
  end

  test "MA-03: gatekeeper verdict REBUILT after restart (EMPTY gate_evals) -> completion, NO silent drop" do
    pid1 = fresh_step_run_consumer()

    send(
      pid1,
      Fleet.Event.new(:spawner, :"pod.completed", payload: build_done("soft", %{"sev" => "high"}))
    )

    assert Map.has_key?(settle(pid1).gate_evals, "corr-1")

    # Stop cleanly and start a fresh consumer; no broker or BEAM restart is exercised.
    :ok = GenServer.stop(pid1)
    pid2 = fresh_step_run_consumer()
    assert settle(pid2).gate_evals == %{}

    # Supply metadata directly rather than retrieving it from a live broker.
    send(
      pid2,
      Fleet.Event.new(:task_queue, :"work_item.completed",
        correlation_id: "corr-1",
        payload: %{
          result: %{"decision" => "continue", "reason" => "all clear"},
          metadata: gate_eval_meta()
        }
      )
    )

    # Settle before checking the forge effects of reconstruction.
    _ = settle(pid2)
    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}
    assert_received {:route, "soft", "review"}

    refute_received :unlocked
  end

  test "MA-03: restart + REBUILT abandon verdict -> close (terminal), no drop" do
    :ok = GenServer.stop(fresh_step_run_consumer())
    pid = fresh_step_run_consumer()
    assert settle(pid).gate_evals == %{}

    send(
      pid,
      Fleet.Event.new(:task_queue, :"work_item.completed",
        correlation_id: "corr-1",
        payload: %{
          result: %{"decision" => "abandon", "reason" => "rebuilt"},
          metadata: gate_eval_meta()
        }
      )
    )

    _ = settle(pid)
    assert_received {:closed, _}
    refute_received {:publish, _}
  end

  test "MA-03: gate_eval work_item.completed but TRUNCATED metadata (resume_payload absent) -> no resume (fail-loud), no crash" do
    pid = fresh_step_run_consumer()

    bad_meta = gate_eval_meta() |> Map.delete("resume_payload")

    send(
      pid,
      Fleet.Event.new(:task_queue, :"work_item.completed",
        correlation_id: "corr-1",
        payload: %{result: %{"decision" => "continue"}, metadata: bad_meta}
      )
    )

    assert Process.alive?(pid)
    assert settle(pid).gate_evals == %{}
    refute_received {:open_pr, _, _, _}
  end

  describe "one fact, one vocabulary — the system translates, not the pod (2026-08-05)" do
    alias Fleet.Pilot.StepRunConsumer.TerminalEscalation
    alias Fleet.Pilot.StepRunConsumer.Verdict

    # Normalize subagent status/concerns into system blocked/summary fields.

    test "a forwarded BLOCKED report escalates instead of delivering silently" do
      report = %{"status" => "BLOCKED", "task_id" => "3", "concerns" => ["spec manquante"]}

      unwrapped = Verdict.unwrap_worker_envelope(report)

      assert TerminalEscalation.blocked_flag?(unwrapped)
      assert Verdict.eng_summary(%{"result" => report}) =~ "spec manquante"
    end

    test "NEEDS_CONTEXT counts as blocked — same family, same wedge" do
      assert %{"status" => "NEEDS_CONTEXT"}
             |> Verdict.unwrap_worker_envelope()
             |> TerminalEscalation.blocked_flag?()
    end

    test "case-insensitive: an LLM writing `blocked` must not slip through a string comparison" do
      assert %{"status" => "blocked"}
             |> Verdict.unwrap_worker_envelope()
             |> TerminalEscalation.blocked_flag?()
    end

    test "the outer status of the enveloped shape is CARRIED IN, not dropped" do
      enveloped = %{"status" => "BLOCKED", "result" => %{"concerns" => ["il manque X"]}}

      unwrapped = Verdict.unwrap_worker_envelope(enveloped)

      assert TerminalEscalation.blocked_flag?(unwrapped)
      assert unwrapped["summary"] =~ "il manque X"
    end

    test "FAIL-SAFE — a blocked status wins over an explicit `blocked: false`" do
      # Explicit blocked:false must not override a blocking status.
      assert %{"status" => "BLOCKED", "blocked" => false}
             |> Verdict.unwrap_worker_envelope()
             |> TerminalEscalation.blocked_flag?()
    end

    test "INVERSE TWIN — a DONE report is untouched, and its own summary wins over concerns" do
      done = %{"status" => "DONE", "summary" => "fait X", "concerns" => ["broutille"]}
      unwrapped = Verdict.unwrap_worker_envelope(done)

      refute TerminalEscalation.blocked_flag?(unwrapped)
      assert unwrapped["summary"] == "fait X"
    end

    test "INVERSE TWIN — a judge verdict passes through untouched" do
      judge = %{"decision" => "continue", "reason" => "ok"}

      assert Verdict.unwrap_worker_envelope(judge) == judge
    end
  end
end
