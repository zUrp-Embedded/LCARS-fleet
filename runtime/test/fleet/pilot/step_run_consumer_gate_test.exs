defmodule Fleet.Pilot.StepRunConsumerGateTest do
  @moduledoc """
  A2.3 / B (L441) — the FINISHED step's gate decides the end-of-step-run. Engineer-first: the
  producer step (engineer, git_native) finishes, its gate decides, and the step_run is PR-native:

    * gate :pass               -> advance (request_review of the next judge + set_assignee bridge)
    * gate {:fail}             -> producer bounce (re-dispatch, NO PR), BOUNDED (step_run budget)
    * budget exhausted         -> {:error, {:rework_exhausted, _}} (no forge write)
    * soft/undecidable gate    -> gatekeeper ESCALATION (unchanged); the verdict comes back async:
      resume_gate continue->advance(PR), abandon->close(§5), human->await_arch(§5).
  """
  use ExUnit.Case, async: true
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Pilot.StepRunConsumer
  alias Fleet.Pilot.StubTaskQueue

  # Forge sim: §5 (abandon/await) + PR primitives. Step_run counter via forge_opts[:_step_runs].
  defmodule StubForge do
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    def get_route(_r, _n, _o), do: :none

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    # `_sign_fails` (via forge_opts) forces the gate-fail SIGNATURE post to fail (forge write
    # outage) while every other post still succeeds → the failed run cannot be signed onto the
    # budget counter, exercising the "unsigned run must NOT bounce" path.
    def post_comment(_r, _n, body, o) do
      if body =~ "gate-fail" and Keyword.get(o, :_sign_fails, false) do
        {:error, :forge_write_down}
      else
        send(self(), {:comment, body}) && {:ok, :posted}
      end
    end

    def set_assignee(_r, _n, login, _o), do: send(self(), {:assignee, login}) && {:ok, :set}
    def remove_label(_r, _n, _l, _o), do: send(self(), :unlocked) && {:ok, :removed}
    def add_label(_r, _n, label, _o), do: send(self(), {:label, label}) && {:ok, :added}

    # La CLOTURE voyage dans le message. Le stub la jetait (`_o`), donc aucun test ne pouvait voir la
    # difference entre « livre » et « abandonne » — et l'abandon fermait en `:delivered` depuis
    # toujours, sans que rien ne rougisse.
    def close_issue(_r, _n, o),
      do: send(self(), {:closed, Keyword.get(o, :closure)}) && {:ok, :closed}

    # Le chronometre PARLE : c'est le seul geste qui distingue `unlock/6` d'un `remove_label` nu,
    # donc l'observer prouve par quel chemin l'escalade est passee.
    def stop_stopwatch(_r, _n, _o), do: send(self(), :stopwatch_stopped) && :ok
    def count_signed_step_runs(_r, _n, opts), do: {:ok, Keyword.get(opts, :_step_runs, 0)}
    def post_route(_r, _n, p, s, _o), do: send(self(), {:route, p, s}) && {:ok, :posted}

    def open_pr(_r, head, base, _t, o),
      do: send(self(), {:open_pr, head, base, o[:body]}) && {:ok, 7}

    def get_pr_for_branch(_r, head, base, _o), do: send(self(), {:get_pr, head, base}) && {:ok, 7}
    # #8.E: a BRIEF judge (brief-review) is PRE-PR → no producer PR open.
    def list_open_pulls(_r, _o), do: {:ok, []}
    def request_review(_r, pr, revs, _o), do: send(self(), {:request_review, pr, revs}) && :ok
    def post_review(_r, pr, ev, body, _o), do: send(self(), {:review, pr, ev, body}) && :ok
    def merge_pr(_r, pr, _o), do: send(self(), {:merge, pr}) && :ok
    def set_stage(_r, _n, _s, _o), do: {:ok, :posted}
  end

  defmodule DelivStub do
    def publish(o) do
      send(self(), {:publish, o})
      {:ok, %{commit_sha: "sha-x", pushed?: true, mode: Map.get(o, :mode, :git_native)}}
    end
  end

  defmodule StubSpawner do
    def wake_pod(pod_id), do: send(self(), {:wake, pod_id}) && :ok

    # Content-carrying arch notification (terminal abandon): the message rides the wake.
    def notify_pod(pod_id, message), do: send(self(), {:notify, pod_id, message}) && :ok

    # One-shot gatekeeper spawn (reorg 2026-07-19): captured + succeeds.
    def spawn_pod(_cap, pod_id, opts) do
      send(self(), {:spawned, pod_id, opts})
      {:ok, self()}
    end
  end

  # Spawn failure stub — proves a judge-less eval fails LOUD (never a silent stall).
  defmodule FailSpawner do
    def wake_pod(pod_id), do: send(self(), {:wake, pod_id}) && :ok
    def spawn_pod(_cap, _pod_id, _opts), do: {:error, :launch_failed}
  end

  # Engineer-first 2-step WorkflowMaps: build(engineer, producer) -> review(reviewer, judge).
  # `gated`: hard gate on build. `soft`: soft gate on build (B -> escalation). `plain`: none.
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

    # Proof "budget = map DATA": same shape as "gated" but declared budget 4 (→ total 2×5=10).
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

    # #8.E: brief-gate workflow_map — root step brief-review (the scoper JUDGES the BRIEF,
    # pre-PR) -> build.
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

    # BL-6-20: same shape as `mandgate` but the judge step declares NOTHING — the card omission
    # that used to silently hard-gate a native judge's verdict. The STAMPED payload closes it.
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

    # MA-12: 1-step workflow_map `build`(engineer, PRODUCER) TERMINAL with a SOFT gate → gatekeeper
    # escalation. A gatekeeper "continue" verdict on this producer terminal used to :promote (merge
    # WITHOUT judges, regression #8.F); the fix routes via tag_advance(_, producer?) → :review
    # (PR + judges).
    def load!("softterm") do
      %{
        "name" => "softterm",
        "max_rework_rounds" => 2,
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => [], "gate" => %{"type" => "soft"}}
        }
      }
    end

    # D2/G3: 1-step workflow_map with terminal gate `human_approval_required` (like standard-qa
    # brainstorm/plan/spec). Human approval → DIRECT arch escalation (not a rework).
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

  # A completer whose close FAILS on the forge — the abandon witness proves nobody is kicked then.
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
      # MA-17 — wake recovery seam (default = the real fn; a test injects it to simulate escalation).
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      gate_evals: %{}
    }
  end

  # pod.completed of the producer step `build` (engineer) that just finished, with its result.
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

  # resume context as gate_decide builds it at escalation ("soft" workflow_map).
  defp soft_ctx do
    %{
      n: 1,
      role: "engineer",
      payload: build_done("soft", %{"x" => 1}),
      workflow_map: WorkflowMap.load!("soft"),
      step: "build"
    }
  end

  # ── Happy path: pass / fail / budget ────────────────────────────────────────

  test "gate :pass -> producer :advance: opens the PR, request_review(reviewer), records the route" do
    assert {:ok, :review_requested} =
             StepRunConsumer.maybe_complete(build_done("gated", %{"ok" => true}), hc())

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}

    # no more set_assignee (PR-driven): the workflow_map position is recorded (route), the trigger = the review
    refute_received {:assignee, _}
    assert_received {:route, "gated", "review"}

    # The ISSUE lock is NOT lifted at advance anymore — persists until the final :promote.
    refute_received :unlocked
  end

  test "producer/judge classification consumes the EFFECTIVE payload mode, not a since-spawn re-derivation" do
    # The pod ran as a PRODUCER (payload carries deliverable_mode: git_native). Since spawn, a modop/profile
    # change would make the seam RE-DERIVE "payload" (judge). The completion must classify by the mode the
    # pod ACTUALLY ran with (producer → opens the PR), never the drifted re-derivation (which would treat a
    # producer as a judge → the code deliverable would never open a PR).
    payload = Map.put(build_done("gated", %{"ok" => true}), "deliverable_mode", "git_native")
    drifted = hc(deliverable_mode_fun: fn _role, _root -> {:ok, "payload"} end)

    assert {:ok, :review_requested} = StepRunConsumer.maybe_complete(payload, drifted)

    # Classified as PRODUCER from the payload mode, despite the seam disagreeing.
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

    # producer rework: no set_assignee (the engineer stays assigned by Entry); route bounced
    refute_received {:assignee, _}
    assert_received {:route, "gated", "build"}
    assert_received :unlocked
    refute_received {:open_pr, _, _, _}
  end

  test "gate {:fail} + budget exhausted -> ESCALATION await_arch (end of G2 churn), no more log-only {:error}" do
    # budget = nb_steps(2) * (max_rework_rounds(2) + 1) = 6; step_runs already at 6 => exhausted.
    # G2 bug: {:error, {:rework_exhausted}} bubbled up as a log-only {:noreply} -> the reaper
    # re-dispatched -> re-fail -> infinite churn without human notification. NOW: escalation to the
    # arch (comment + lcars-awaits-arch + unlock) -> the poller skips the issue -> the human decides.
    payload = build_done("gated", %{})

    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(payload, hc(forge_opts: [_step_runs: 6]))

    assert_received {:label, "lcars-awaits-arch"}

    # LOAD-BEARING unlock: removes lcars-in-flight -> the poller stops re-dispatching (end of churn).
    assert_received :unlocked

    # Et c'est un VRAI `unlock/6`, pas un `remove_label` nu : le chronometre Gitea du role est
    # arrete. Il tournait auparavant pendant TOUTE l'attente humaine — qui peut durer des jours —
    # et `step.unlocked` n'etait pas emis, donc le seul etat que l'arch doit voir arriver etait le
    # seul a ne produire aucune ligne de feed.
    assert_received :stopwatch_stopped
    # The FAILED run is SIGNED first (anti-runaway: the budget counts it), THEN the
    # escalation comment ("Architecte" pins the FR user-facing one).
    assert_received {:comment, fail_trace}
    assert fail_trace =~ "gate-fail"
    assert_received {:comment, body}
    assert body =~ "Rework"
    assert body =~ "Architecte"
    # IMMEDIATE offer-then-wake (design 2026-07-19) — order proven in the escalate_user test.
    assert_received {:enqueued, "architect-r", _}
    assert_received {:wake, "architect-r"}
    # human escalation, NOT a bounce (PR) nor an abandon (close).
    refute_received {:open_pr, _, _, _}
    refute_received {:closed, _}
  end

  test "gate {:fail} but the failed-run SIGNATURE post fails -> ESCALATION, not an unbudgeted bounce" do
    # sign_failed_run posts the `[step_run:gate-fail]` marker the rework budget counts. If that
    # POST fails (forge write outage), the run is UNSIGNED — bouncing on it would freeze the
    # counter while rework keeps spawning (the live 2026-07-18 runaway, ~25 spawns). Under budget
    # (0/6) the gate would normally bounce; with the signature KO it must ESCALATE instead (surface
    # `:gate_fail_unsigned`, never guess). A swallowed signature error (`:ok`) reopened this hole.
    payload = build_done("gated", %{})

    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(
               payload,
               hc(forge_opts: [_step_runs: 0, _sign_fails: true])
             )

    # LOAD-BEARING regression: NO bounce back to the first step, despite being under budget.
    refute_received {:route, "gated", "build"}
    refute_received {:open_pr, _, _, _}

    # Escalated to the arch: frozen (await-arch), unlocked (churn stops), FR message names the cause.
    assert_received {:label, "lcars-awaits-arch"}
    assert_received :unlocked
    assert_received {:comment, body}
    assert body =~ "non comptabilisé"
    assert body =~ "Architecte"
    assert_received {:enqueued, "architect-r", _}
    assert_received {:wake, "architect-r"}
  end

  test "terminal human_approval gate -> DIRECT ESCALATION await_arch (D2, no 6 wasted rework rounds)" do
    # human_approval is NOT a gate failure: DIRECT human escalation (await_arch), without going
    # through rework (which would waste `budget` producer spawns before escalating anyway).
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(build_done("humanapp", %{}), hc())

    assert_received {:label, "lcars-awaits-arch"}
    assert_received :unlocked
    assert_received {:comment, body}
    # "Aval humain" / "Architecte" pin the FR user-facing escalation comment.
    assert body =~ "Aval humain"
    assert body =~ "Architecte"
    # IMMEDIATE offer-then-wake (design 2026-07-19) — order proven in the escalate_user test.
    assert_received {:enqueued, "architect-r", _}
    assert_received {:wake, "architect-r"}
    # escalation, NOT a bounce (rework) nor a PR.
    refute_received {:open_pr, _, _, _}
  end

  test "budget: just under the limit bounces, right at the limit ESCALATES (await_arch, no more churn)" do
    payload = build_done("gated", %{})

    assert {:ok, :rework_requested} =
             StepRunConsumer.maybe_complete(payload, hc(forge_opts: [_step_runs: 5]))

    # right at the limit: budget exhausted -> human escalation (await_arch), no more swallowed {:error} (G2).
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(payload, hc(forge_opts: [_step_runs: 6]))
  end

  test "map-level budget HONORED: gated4(max_rework_rounds:4) bounces where gated(2) escalates" do
    # Proof that the budget comes from the map's DATA, not a coded default: gated4 declares
    # max_rework_rounds:4 → budget = nb_steps(2) × (4+1) = 10. At 6 step_runs, gated(budget 6)
    # ESCALATES (test above) but gated4(budget 10) still BOUNCES; at 10, gated4 escalates in turn.
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

  # ── B (L441): gatekeeper escalation (soft gate on the producer step) ────────

  test "soft gate -> ESCALATION: brief enqueued THEN one-shot gatekeeper SPAWNED (offer-then-spawn)" do
    assert {:escalate, "corr-1", ctx} =
             StepRunConsumer.maybe_complete(build_done("soft", %{"sev" => "high"}), hc())

    assert ctx.step == "build"
    assert ctx.role == "engineer"

    # Judge naming (reorg 2026-07-19): one pod per eval'd issue, project-bound one-shot.
    assert_received {:enqueued, "o-r-issue-1-gatekeeper", attrs}
    assert attrs.role == "gatekeeper"
    assert attrs.metadata["gate_eval"] == true
    assert attrs.metadata["step"] == "build"
    assert is_binary(attrs.brief)
    assert attrs.metadata["outputs"] == %{"sev" => "high"}

    # The one-shot spawn (its boot kick pulls the enqueued brief — no separate wake needed).
    assert_received {:spawned, "o-r-issue-1-gatekeeper", spawn_opts}
    assert spawn_opts[:repo] == "o/r"
    assert is_binary(spawn_opts[:brief])

    refute_received {:assignee, _}
    refute_received {:open_pr, _, _, _}
    refute_received :unlocked
  end

  # ⚖ Pinned as it IS (2026-09-05): on `{:escalate, _, _}` the journal entry is REMOVED — the
  # broker's queued brief takes over, and its metadata rebuild the context after a consumer restart
  # (`reconstruct_eval_ctx/2`); the broker itself is ephemeral, so a BEAM restart mid-escalation
  # loses both, which the code says. A change of that choice must flip this witness knowingly.
  test "escalation through handle_info: the completion is NOT kept owed in the outbox" do
    wi = "wi-esc-#{System.unique_integer([:positive])}"

    event =
      Fleet.Event.new(:spawner, :"pod.completed",
        payload:
          build_done("soft", %{"sev" => "high"})
          |> Map.put("work_item_id", wi)
          |> Map.put("pod_id", "pod-esc")
      )

    # The payload IS journalable (a `work_item_id`-less one would make the refute below vacuous).
    assert {:ok, _} = Fleet.Pilot.CompletionOutbox.put(event.payload)
    assert Enum.any?(Fleet.Pilot.CompletionOutbox.pending(), &(&1["work_item_id"] == wi))

    assert {:noreply, _} = StepRunConsumer.handle_info(event, hc())
    assert_received {:enqueued, "o-r-issue-1-gatekeeper", _}

    refute Enum.any?(Fleet.Pilot.CompletionOutbox.pending(), &(&1["work_item_id"] == wi)),
           "an escalated completion is acknowledged in the journal, by choice"
  end

  test "escalation: gatekeeper already ALIVE (previous eval closing) → enqueue + wake, no double spawn" do
    # {:already_started} from the spawner → the brief is queued, a plain wake nudges the live pod.
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
    # Before the fix: `already_started` + a failed `wake_pod` was SWALLOWED to
    # `:ok` → the eval brief sat pending, the gate announced-but-never-run, the issue silently locked with
    # NO failure reported. Now the wake routes through the injectable WakeRecovery; its verdict is
    # SURFACED (fail-loud upstream → issue visible). Stubbed here (the real WakeRecovery would hit
    # IncidentRegistry + a sysadmin forge escalation): assert it IS invoked (the wake is no longer
    # swallowed) and that its error verdict propagates as a dispatch failure.
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
    # Reorg 2026-07-19: the gatekeeper is spawned one-shot per eval — a failed spawn means no judge
    # will ever pull the brief → the dispatch fail-louds (issue stays locked, visible).
    state = hc(spawner: FailSpawner)

    assert {:error, {:gatekeeper_dispatch, {:gatekeeper_spawn, :launch_failed}}} =
             StepRunConsumer.maybe_complete(build_done("soft", %{}), state)

    refute_received {:assignee, _}
    refute_received :unlocked
  end

  # ── B: resume on the gatekeeper's verdict (resume_gate/3) ──────────────────
  # NB: continue goes through complete_pr (PR-native). The verdict trace is NOT yet materialized on
  # the PR (transitional gap); abandon/await keep the §5 sequence (trace ok).

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

    # The ISSUE lock is NOT lifted at advance anymore — persists until the final :promote.
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

    # `:retired`, JAMAIS `:delivered`. `:delivered` pose `stage/merged`, donc `outcome/3` rend
    # `"merged"` — la valeur que la description de l'outil presente a l'architecte comme la preuve
    # de livraison sur laquelle enchainer. Un abandon invitait a chainer dessus.
    assert_received {:closed, :retired}
    refute_received {:publish, _}
    refute_received {:assignee, _}

    # abandon NOTIFIES the arch (user airlock) with CONTENT: the terminal wake carries the abandon
    # message (notify_pod, no phantom mandate on a closed issue), never a content-less wake_pod.
    assert_received {:notify, "architect-r", notice}
    assert notice =~ "ABANDONNÉ"
    refute_received {:wake, "architect-r"}
    assert_received {:comment, abody}
    assert abody =~ "Architecte"
  end

  test "abandon under OFFLOAD: the arch is kicked AFTER the close reached the forge, never before" do
    # 2026-09-05 — the kick used to follow `close_with_trace` in the caller; under a runner the
    # closure is handed over and `{:ok, :offloaded}` returns at once, so the architect heard of an
    # abandon the forge had not recorded — and heard of it even when the close failed. Pinned here
    # with a runner that HOLDS the closure: nothing may reach the arch until it runs.
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
    # `:ops_root` is the consumer's seam: without it the pin can only be watched on the real global
    # path. The face is a git repo with no remote (the push to `ops` fails, best-effort; the COMMIT
    # is what makes the object addressable — a file written without a commit is a crash residue,
    # so the witness reads the git log, not the disk).
    work_dir = Path.join(tmp, "r")
    File.mkdir_p!(work_dir)
    {_, 0} = System.cmd("git", ["init", "-q", work_dir])
    {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.email", "t@lcars.local"])
    {_, 0} = System.cmd("git", ["-C", work_dir, "config", "user.name", "t"])

    # Long enough to be pinned (`Pinning.pinnable?/1`): a one-line verdict stays inline by design.
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

    # #5.2 — comment ADDRESSED to the arch (single airlock).
    assert body =~ "Architecte"

    # Design 2026-07-19 ("first kick immediate, protection BEHIND"): freeze_to_arch fires the
    # IMMEDIATE offer-then-wake — and the ORDER is the invariant (mandate enqueued BEFORE the
    # wake, killing the 2026-07-18 signal-before-content race where the woken arch read
    # `{done:true}`). The mailbox preserves arrival order: prove enqueue < wake positionally.
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
    # gate-decision.json requires `reason` (minLength 1); the decoder now ENFORCES it (not just
    # the decision enum). A `continue` without a motive = approval without a durable trace (what
    # sank v1) → refused: halt_invalid → human escalation. The decision stays valid, but the
    # verdict is malformed.
    assert "continue" ==
             Fleet.Pilot.StepRunConsumer.Verdict.gate_decision(%{
               "decision" => "continue",
               "reason" => "criterion ok"
             })

    assert "halt_invalid" ==
             Fleet.Pilot.StepRunConsumer.Verdict.gate_decision(%{"decision" => "continue"})

    assert "halt_invalid" ==
             Fleet.Pilot.StepRunConsumer.Verdict.gate_decision(%{
               "decision" => "continue",
               "reason" => ""
             })

    # End-to-end: a `continue` without reason does NOT promote/advance — it escalates (await_arch),
    # never a merge.
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "continue"}},
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
  end

  test "wire envelope EXECUTED at the frontier: mistyped details/chain → halt_invalid, logged" do
    # gate-decision.json types `details: object` and `chain: array[string]`. The decoder used
    # to check only enum+reason: a schema-invalid approval crossed and its rich trace was silently
    # dropped at rendering. The full envelope now validates on ingest, fail-closed.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert "halt_invalid" ==
                 Fleet.Pilot.StepRunConsumer.Verdict.gate_decision(%{
                   "decision" => "continue",
                   "reason" => "criterion ok",
                   "details" => "oops",
                   "chain" => "oops"
                 })

        assert "halt_invalid" ==
                 Fleet.Pilot.StepRunConsumer.Verdict.gate_decision(%{
                   "decision" => "continue",
                   "reason" => "criterion ok",
                   "chain" => [%{"step" => "reading"}, 42]
                 })
      end)

    # The refusal names its cause on the operator rail — "illisible" alone is not diagnosable.
    assert log =~ "envelope invalid"

    # Well-typed optional fields still cross.
    assert "continue" ==
             Fleet.Pilot.StepRunConsumer.Verdict.gate_decision(%{
               "decision" => "continue",
               "reason" => "criterion ok",
               "details" => %{"critere" => "ok"},
               "chain" => ["read", "checked"]
             })

    # End-to-end: a schema-invalid `continue` does NOT advance — await_arch, never a merge.
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
    # "illisible ou absent" pins the FR user-facing escalation comment.
    assert body =~ "illisible ou absent"
  end

  # ── MA-12: "continue" verdict on a TERMINAL PRODUCER → :review (PR + judges), NEVER :promote ──
  # The bug: `apply_verdict` "continue" hardcoded `intent = if is_nil(next_assignee), do: :promote`
  # → on a terminal, ALWAYS :promote, ignoring the finishing role → a PRODUCER judged continue
  # merged WITHOUT judges (#8.F reopening). The fix routes via
  # tag_advance(advance(...), producer?(role)) — same split as the gate :pass path. NB: this path
  # (gatekeeper "continue" verdict) is DISTINCT from the `gate :pass terminal producer` test above
  # (which goes through gate_decide, not apply_verdict).

  # resume ctx for a softterm workflow_map (build engineer = TERMINAL producer, soft gate).
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

    # the terminal producer OPENS the PR + requests the judge(s) — it NEVER merges alone.
    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, _revs}
    # THE finding: NO direct merge (the :promote bug would have merged without judges).
    refute_received {:merge, _}
  end

  # ── #8.E: verdict of a BRIEF judge (brief-review/scoper) via pod.completed ──────────
  # SAME apply_verdict as the gatekeeper (factored); the scoper is PRE-PR → ISSUE-LEVEL advance
  # (records the route, no PR) and trace attributed to the SCOPER (not "gatekeeper").

  # pod.completed of the brief-review step (scoper) that just returned its verdict.
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

    # ISSUE-LEVEL advance: records the route to build; NO PR opened (the scoper judges pre-PR).
    assert_received {:route, "mandgate", "build"}
    refute_received {:open_pr, _, _, _}
    refute_received {:assignee, _}
    assert_received :unlocked
    # trace attributed to the SCOPER (honest), not the gatekeeper.
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

  # ── BL-6-20: judge-ness is STAMPED at dispatch (payload wins), step-spec = legacy fallback ──

  test "BL-6-20: a STAMPED judge payload routes as a judge even when the card declares NOTHING" do
    # The fail-open this closes: same payload on the undeclared card WITHOUT the stamp used to
    # have its verdict hard-gated as producer output (the legacy pin below keeps that measured).
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

    # The MEASURED legacy (and the very bug the stamp closes): the judge's verdict is treated as
    # producer output — the completion goes PR-native and dies looking for a producer branch that
    # a pre-PR judge never pushed. Pods spawned before the stamp keep exactly this behavior; the
    # pin is deliberately the honest wart, not a cleaned-up outcome.
    assert {:error, {:pr_lookup, :no_producer_branch}} =
             StepRunConsumer.maybe_complete(payload, hc())

    refute_received {:label, "lcars-awaits-arch"}
  end

  test "BL-6-20: the stamp WINS over the step declaration (the effective fact travels)" do
    # A worker-stamped payload on a judge-declared step cannot come from our dispatcher (the
    # dispatch resolves step || profile) — but if it arrives, the pod RAN as a worker and its
    # payload says so: same doctrine as deliverable_mode (never re-derived downstream). Worker
    # treatment of a pre-PR payload = the same measured PR-native dead end as above.
    payload =
      brief_done(%{"decision" => "escalate_user", "reason" => "not a verdict"})
      |> Map.put("brief_kind", "worker")

    assert {:error, {:pr_lookup, :no_producer_branch}} =
             StepRunConsumer.maybe_complete(payload, hc())

    refute_received {:label, "lcars-awaits-arch"}
  end

  # ── #8-fix "a producer NEVER merges alone" ───────────────────────────────────────
  test "terminal producer (build, last step of the workflow_map) -> :review (PR + judges), NEVER :promote/merge" do
    # mandgate = brief-review -> build; build (engineer, producer) is TERMINAL. Before the fix it
    # did :promote (merge without judges = #8.F regression). With it: :review -> opens the PR +
    # requests [qualifier, reviewer]; the proven PR-driven path (dispatch_by_verdicts) then seals
    # at the gatekeeper.
    assert {:ok, :review_requested} =
             StepRunConsumer.maybe_complete(build_done("mandgate", %{}), hc())

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["qualifier", "reviewer"]}
    refute_received {:merge, _}
  end

  # ── B: async wiring (GenServer) — stores gate_evals at escalation, pops at resume ──

  test "GenServer: soft pod.completed -> gate_evals stores; correlated work_item.completed -> pop" do
    {:ok, pid} =
      StepRunConsumer.start_link(
        # UNIQUE name per test: this file is `async: true` and `start_link` without `:name` falls
        # back to the global name `StepRunConsumer` → two co-scheduled GenServer tests
        # collide with `{:already_started}`. A unique name isolates each instance (the test drives
        # `pid`, not the name).
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
    # gate_evals only shrank on the correlated completion: a superseded eval (new enqueue on the
    # gatekeeper) or a cleared one (pod death) left its context — payload + ENTIRE workflow_map —
    # in RAM for life in this singleton (monotonic daemon growth). Without a verdict there is
    # NOTHING to resume; and a late verdict would rebuild itself from the broker's self-describing
    # metadata.
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
    # The work_item.cleared rail is LOSSY (doctrine D1) and a gatekeeper dying mid-eval emits
    # NOTHING: the TTL is the ramp that depends on no message. ttl/sweep seams at ~0 to exercise
    # the mechanics without waiting 2h (a TTL only testable by waiting is not tested).
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
        # LONG cadence: we do NOT want to race the automatic tick (under load it would arrive
        # whenever it pleases → flaky test). We DRIVE the sweep by sending its message, then
        # synchronize with the :sys.get_state FIFO barrier. Deterministic, zero sleep.
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
        # Unique name: `async: true` + `start_link` without `:name` → `{:already_started}` collision
        # on the global name between co-scheduled GenServer tests. Isolation by unique name (the
        # test drives `pid`).
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
        # MA-03: payload WITHOUT gate_eval metadata (the NORMAL case — an ordinary step-dispatch
        # pod) → ignored.
        payload: %{result: %{"decision" => "continue"}}
      )
    )

    assert %{gate_evals: evals} = settle(pid)
    assert evals == %{}
  end

  # ── MA-03: the gatekeeper verdict SURVIVES a StepRunConsumer restart (self-describing verdict) ──
  # The closed wedge: crash of the StepRunConsumer ALONE (broker alive). The resume context is no
  # longer in RAM (`gate_evals` empty at restart); it TRAVELS in the eval TASK's metadata (which
  # survives in the broker) → brought back by `work_item.completed` → reconstruction → resume.
  # Before MA-03: silent `{nil,_} -> {:noreply}` (verdict discarded, issue locked forever).

  # The eval task's metadata, as `dispatch_gatekeeper` embeds it + as `task_queue/server.ex` puts
  # it in the `work_item.completed` payload. Carries the resume context (resume_payload/n/role).
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

  # Forge/deliverable stubs that RELAY to the test pid carried in `forge_opts[:test_pid]`. Needed
  # for the GenServer tests: the forge effects run INSIDE the StepRunConsumer's process
  # (`self()` ≠ test) → a `send(self(), …)` would not reach the test. The pid is threaded via
  # `forge_opts` (already passed to the forge_client by `StepRunCompleter`). DelivStub has no opts
  # → relayed via the pid stored at test init.
  defmodule RelayForge do
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    defp relay(opts, msg), do: send(Keyword.fetch!(opts, :test_pid), msg)
    def post_comment(_r, _n, body, o), do: relay(o, {:comment, body}) && {:ok, :posted}
    def set_assignee(_r, _n, l, o), do: relay(o, {:assignee, l}) && {:ok, :set}
    def remove_label(_r, _n, _l, o), do: relay(o, :unlocked) && {:ok, :removed}
    def add_label(_r, _n, label, o), do: relay(o, {:label, label}) && {:ok, :added}
    # Jumeau du stub d'en haut : la CLOTURE voyage, sinon `:delivered` et `:retired` sont le meme
    # message et aucun test ne peut les separer.
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
    # `deliverable: DelivStub` → its `{:publish, _}` goes to the GenServer (`self()` on the pod
    # side); we do NOT assert on it (observable effects go through RelayForge/forge_opts). The push
    # succeeds (git_native mode).
    {:ok, pid} =
      StepRunConsumer.start_link(
        # Unique name: `async: true` + `start_link` without `:name` → `{:already_started}` collision
        # on the global name between co-scheduled GenServer tests. Isolation by unique name (the
        # test drives `pid`).
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
    # 1. escalation on a 1st StepRunConsumer → gate_evals populated.
    pid1 = fresh_step_run_consumer()

    send(
      pid1,
      Fleet.Event.new(:spawner, :"pod.completed", payload: build_done("soft", %{"sev" => "high"}))
    )

    assert Map.has_key?(settle(pid1).gate_evals, "corr-1")

    # 2. CRASH of the StepRunConsumer ALONE (the broker would stay alive in prod) → we stop it +
    #    start a FRESH one. The fresh one has EMPTY gate_evals — exactly the post-crash state where
    #    the old code discarded the verdict.
    :ok = GenServer.stop(pid1)
    pid2 = fresh_step_run_consumer()
    assert settle(pid2).gate_evals == %{}

    # 3. The verdict comes back (the task's metadata survived in the broker → put in work_item.completed).
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

    # 4. RECONSTRUCTION + COMPLETION: the `continue` verdict opens the PR + request_review + route
    #    — NOT a silent {:noreply}. (`:sys.get_state` after the send serializes the handle_info →
    #    the effect has happened.)
    _ = settle(pid2)
    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}
    assert_received {:route, "soft", "review"}

    # The ISSUE lock is NOT lifted at advance anymore — persists until the final :promote.
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

    # The singleton does not crash, and does NOT act on a truncated context (no PR opened blindly).
    assert Process.alive?(pid)
    assert settle(pid).gate_evals == %{}
    refute_received {:open_pr, _, _, _}
  end

  describe "one fact, one vocabulary — the system translates, not the pod (2026-08-05)" do
    alias Fleet.Pilot.StepRunConsumer.TerminalEscalation
    alias Fleet.Pilot.StepRunConsumer.Verdict

    # Three vocabularies were in play for the same fact: the system reads `summary`/`blocked`, the
    # `subagent-driven` modop teaches its subagents `status: "BLOCKED|NEEDS_CONTEXT"` + `concerns`,
    # and the envelope clause tolerated a shape no live producer emits. The shape actually produced
    # matched neither — a pod forwarding its subagent's refusal DELIVERED IN SILENCE.

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
      # It used to be discarded one function before the field that reads it.
      enveloped = %{"status" => "BLOCKED", "result" => %{"concerns" => ["il manque X"]}}

      unwrapped = Verdict.unwrap_worker_envelope(enveloped)

      assert TerminalEscalation.blocked_flag?(unwrapped)
      assert unwrapped["summary"] =~ "il manque X"
    end

    test "FAIL-SAFE — a blocked status wins over an explicit `blocked: false`" do
      # Asymmetric on purpose: a false positive costs a human one glance; a miss costs a silent
      # wedge and a brick nobody knows is stuck.
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
