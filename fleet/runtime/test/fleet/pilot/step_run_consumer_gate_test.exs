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

  alias Fleet.Pilot.StepRunConsumer
  alias Fleet.Pilot.StubTaskQueue

  # Forge sim: §5 (abandon/await) + PR primitives. Step_run counter via forge_opts[:_step_runs].
  defmodule StubForge do
    def post_comment(_r, _n, body, _o), do: send(self(), {:comment, body}) && {:ok, :posted}
    def set_assignee(_r, _n, login, _o), do: send(self(), {:assignee, login}) && {:ok, :set}
    def remove_label(_r, _n, _l, _o), do: send(self(), :unlocked) && {:ok, :removed}
    def add_label(_r, _n, label, _o), do: send(self(), {:label, label}) && {:ok, :added}
    def close_issue(_r, _n, _o), do: send(self(), :closed) && {:ok, :closed}
    def stop_stopwatch(_r, _n, _o), do: :ok
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

    # #8.E: brief-gate workflow_map — root step brief-review (the consultant JUDGES the BRIEF,
    # pre-PR) -> build.
    def load!("mandgate") do
      %{
        "name" => "mandgate",
        "max_rework_rounds" => 2,
        "steps" => %{
          "brief-review" => %{
            "role" => "consultant",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "brief"
          },
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

  defp dmode,
    do: fn
      "engineer" -> {:ok, "git_native"}
      _ -> {:ok, "payload"}
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
      deliverable_mode_fun: dmode(),
      task_queue: StubTaskQueue,
      spawner: StubSpawner,
      gatekeeper_pod_id_fun: Keyword.get(opts, :gatekeeper_pod_id_fun, fn -> "gatekeeper" end),
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
    # The FAILED run is SIGNED first (anti-runaway: the budget counts it), THEN the
    # escalation comment ("Architecte" pins the FR user-facing one).
    assert_received {:comment, fail_trace}
    assert fail_trace =~ "gate-fail"
    assert_received {:comment, body}
    assert body =~ "Rework"
    assert body =~ "Architecte"
    # IMMEDIATE offer-then-wake (design 2026-07-19) — order proven in the escalate_user test.
    assert_received {:enqueued, "permanent-architect", _}
    assert_received {:wake, "permanent-architect"}
    # human escalation, NOT a bounce (PR) nor an abandon (close).
    refute_received {:open_pr, _, _, _}
    refute_received :closed
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
    assert_received {:enqueued, "permanent-architect", _}
    assert_received {:wake, "permanent-architect"}
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

  test "soft gate -> ESCALATION: brief enqueued, NO advance/forge write" do
    assert {:escalate, "corr-1", ctx} =
             StepRunConsumer.maybe_complete(build_done("soft", %{"sev" => "high"}), hc())

    assert ctx.step == "build"
    assert ctx.role == "engineer"

    assert_received {:enqueued, "gatekeeper", attrs}
    assert attrs.role == "gatekeeper"
    assert attrs.metadata["gate_eval"] == true
    assert attrs.metadata["step"] == "build"
    assert is_binary(attrs.brief)
    assert attrs.metadata["outputs"] == %{"sev" => "high"}
    assert_received {:wake, "gatekeeper"}

    refute_received {:assignee, _}
    refute_received {:open_pr, _, _, _}
    refute_received :unlocked
  end

  # MA-17 — the gatekeeper kick's return is LOAD-BEARING. A `_ = kick_gatekeeper(...)` discarding
  # WakeRecovery.wake's return → a never-woken gatekeeper stayed INVISIBLE (the verdict would never
  # come back, gate silently stalled). The eval brief IS enqueued → the escalation stays legitimate
  # ({:escalate, corr, _}), but the unreachable kick is SURFACED (telemetry), not conflated with an
  # OK kick.
  test "MA-17: gatekeeper kick UNREACHABLE → escalates anyway BUT surfaced via telemetry (not swallowed)" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:fleet_pilot, :step_run_consumer, :gatekeeper_kick_unreached]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    # Seam: the wake recovery ESCALATES (gatekeeper unreachable, re-wake KO → starfleet).
    escalating = fn _pod, _respawn, _opts -> {:error, {:escalated, :dead}} end

    # The escalation stays legitimate: the brief is enqueued, corr returned (the verdict will come
    # back at re-wake).
    assert {:escalate, "corr-1", _ctx} =
             StepRunConsumer.maybe_complete(
               build_done("soft", %{"sev" => "high"}),
               hc(wake_recovery: escalating)
             )

    assert_received {:enqueued, "gatekeeper", _attrs}

    # THE finding: the unreachable kick is SURFACED (telemetry emitted), not silently swallowed.
    assert_received {[:fleet_pilot, :step_run_consumer, :gatekeeper_kick_unreached], ^ref,
                     %{count: 1}, %{pod_id: "gatekeeper", reason: {:escalated, :dead}}}
  end

  test "escalation: ENVELOPED outputs %{status,result} -> unwrapped before the brief (#2)" do
    enveloped = %{"status" => "ok", "result" => %{"sev" => "low"}}

    assert {:escalate, "corr-1", _ctx} =
             StepRunConsumer.maybe_complete(build_done("soft", enveloped), hc())

    assert_received {:enqueued, _pod, attrs}
    assert attrs.metadata["outputs"] == %{"sev" => "low"}
  end

  test "escalation: no gatekeeper booted -> fail-loud (never a silent pass)" do
    state = hc(gatekeeper_pod_id_fun: fn -> nil end)

    assert {:error, {:gatekeeper_dispatch, :no_gatekeeper}} =
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

    assert_received :closed
    refute_received {:publish, _}
    refute_received {:assignee, _}

    # #5.2 — abandon NOTIFIES the arch (user airlock): kick + arch-addressed comment (no silent burial).
    assert_received {:wake, "permanent-architect"}
    assert_received {:comment, abody}
    assert abody =~ "Architecte"
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
    refute_received :closed
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
      Enum.find_index(msgs, &match?({:enqueued, "permanent-architect", _}, &1))

    wake_idx = Enum.find_index(msgs, &match?({:wake, "permanent-architect"}, &1))

    assert enqueue_idx, "expected the arch arbitration mandate to be enqueued (immediate rail)"
    assert wake_idx, "expected the immediate arch wake after the mandate enqueue"
    assert enqueue_idx < wake_idx, "offer must PRECEDE wake (signal-before-content race)"

    assert_received {:enqueued, "permanent-architect", attrs}
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
    # gate-decision-v1.json requires `reason` (minLength 1); the decoder now ENFORCES it (not just
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
    refute_received :closed
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

  # ── #8.E: verdict of a BRIEF judge (brief-review/consultant) via pod.completed ──────────
  # SAME apply_verdict as the gatekeeper (factored); the consultant is PRE-PR → ISSUE-LEVEL advance
  # (records the route, no PR) and trace attributed to the CONSULTANT (not "gatekeeper").

  # pod.completed of the brief-review step (consultant) that just returned its verdict.
  defp brief_done(result),
    do: %{
      "issue_id" => "issue-1",
      "workspace" => "/ws",
      "base_sha" => "cafe",
      "role" => "consultant",
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

    # ISSUE-LEVEL advance: records the route to build; NO PR opened (the consultant judges pre-PR).
    assert_received {:route, "mandgate", "build"}
    refute_received {:open_pr, _, _, _}
    refute_received {:assignee, _}
    assert_received :unlocked
    # trace attributed to the CONSULTANT (honest), not the gatekeeper.
    assert_received {:comment, body}
    assert body =~ "consultant"
    assert body =~ "continue"
  end

  test "#8.E brief-review escalate_user -> await_arch (arch); CONSULTANT trace, not gatekeeper" do
    assert {:ok, :awaiting_arch} =
             StepRunConsumer.maybe_complete(
               brief_done(%{"decision" => "escalate_user", "reason" => "ambiguous brief"}),
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
    assert_received :unlocked
    refute_received {:assignee, _}
    refute_received :closed
    assert_received {:comment, body}
    assert body =~ "consultant"
    refute body =~ "gatekeeper"
  end

  test "#8.E brief-review abandon -> close (brief discarded), NO PR nor push" do
    assert {:ok, :completed} =
             StepRunConsumer.maybe_complete(
               brief_done(%{"decision" => "abandon", "reason" => "brief discarded"}),
               hc()
             )

    assert_received :closed
    refute_received {:open_pr, _, _, _}
    refute_received {:publish, _}
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
        # back to the global name `Fleet.Pilot.StepRunConsumer` → two co-scheduled GenServer tests
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
        gatekeeper_pod_id_fun: fn -> "gk-perm" end,
        role_emails: fn r -> ["#{r}@lcars.local"] end
      )

    send(pid, Fleet.Event.new(:spawner, :"pod.completed", payload: build_done("soft", %{})))

    state = :sys.get_state(pid)
    assert Map.has_key?(state.gate_evals, "corr-1")
    assert %{step: "build"} = state.gate_evals["corr-1"]

    send(
      pid,
      Fleet.Event.new(:task_queue, :"work_item.completed",
        correlation_id: "corr-1",
        payload: %{result: %{"decision" => "continue"}}
      )
    )

    assert %{gate_evals: evals} = :sys.get_state(pid)
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
        gatekeeper_pod_id_fun: fn -> "gk-perm" end,
        role_emails: fn r -> ["#{r}@lcars.local"] end
      )

    send(pid, Fleet.Event.new(:spawner, :"pod.completed", payload: build_done("soft", %{})))
    assert Map.has_key?(:sys.get_state(pid).gate_evals, "corr-1")

    send(
      pid,
      Fleet.Event.new(:task_queue, :"work_item.cleared",
        correlation_id: "corr-1",
        payload: %{work_item_id: "corr-1", reason: :superseded}
      )
    )

    assert %{gate_evals: evals} = :sys.get_state(pid)
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
        gatekeeper_pod_id_fun: fn -> "gk-perm" end,
        role_emails: fn r -> ["#{r}@lcars.local"] end,
        gate_eval_ttl_ms: 0,
        # LONG cadence: we do NOT want to race the automatic tick (under load it would arrive
        # whenever it pleases → flaky test). We DRIVE the sweep by sending its message, then
        # synchronize with the :sys.get_state FIFO barrier. Deterministic, zero sleep.
        gate_eval_sweep_ms: 60_000
      )

    send(pid, Fleet.Event.new(:spawner, :"pod.completed", payload: build_done("soft", %{})))
    assert Map.has_key?(:sys.get_state(pid).gate_evals, "corr-1")

    send(pid, :sweep_gate_evals)

    assert %{gate_evals: evals} = :sys.get_state(pid)
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

    assert %{gate_evals: evals} = :sys.get_state(pid)
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
    defp relay(opts, msg), do: send(Keyword.fetch!(opts, :test_pid), msg)
    def post_comment(_r, _n, body, o), do: relay(o, {:comment, body}) && {:ok, :posted}
    def set_assignee(_r, _n, l, o), do: relay(o, {:assignee, l}) && {:ok, :set}
    def remove_label(_r, _n, _l, o), do: relay(o, :unlocked) && {:ok, :removed}
    def add_label(_r, _n, label, o), do: relay(o, {:label, label}) && {:ok, :added}
    def close_issue(_r, _n, o), do: relay(o, :closed) && {:ok, :closed}
    def stop_stopwatch(_r, _n, _o), do: :ok
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
        gatekeeper_pod_id_fun: fn -> "gk-perm" end,
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

    assert Map.has_key?(:sys.get_state(pid1).gate_evals, "corr-1")

    # 2. CRASH of the StepRunConsumer ALONE (the broker would stay alive in prod) → we stop it +
    #    start a FRESH one. The fresh one has EMPTY gate_evals — exactly the post-crash state where
    #    the old code discarded the verdict.
    :ok = GenServer.stop(pid1)
    pid2 = fresh_step_run_consumer()
    assert :sys.get_state(pid2).gate_evals == %{}

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
    _ = :sys.get_state(pid2)
    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}
    assert_received {:route, "soft", "review"}

    # The ISSUE lock is NOT lifted at advance anymore — persists until the final :promote.
    refute_received :unlocked
  end

  test "MA-03: restart + REBUILT abandon verdict -> close (terminal), no drop" do
    :ok = GenServer.stop(fresh_step_run_consumer())
    pid = fresh_step_run_consumer()
    assert :sys.get_state(pid).gate_evals == %{}

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

    _ = :sys.get_state(pid)
    assert_received :closed
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
    assert :sys.get_state(pid).gate_evals == %{}
    refute_received {:open_pr, _, _, _}
  end
end
