defmodule Fleet.Pilot.StepRunConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepRunConsumer

  # StepRunCompleter seam: captures the received PR-native step_run + returns a fixed outcome.
  defmodule CaptureCompleter do
    def complete_pr(step_run, opts) do
      send(self(), {:step_run, step_run, opts})
      {:ok, :captured}
    end

    # BLOCKED_DEP: blocked-producer escalation → await_arch (captured for assertion).
    def await_arch(step_run, opts) do
      send(self(), {:await_arch, step_run, opts})
      {:ok, :awaiting_arch}
    end
  end

  # Loader seam (A2.4): linear engineer-first workflow_map; "bad" raises (not found).
  #   build(engineer, producer) -> spec(qualifier, judge) -> review(reviewer, terminal judge)
  defmodule StubLoader do
    def load!("poc-cycle") do
      %{
        "name" => "poc-cycle",
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "spec" => %{"role" => "qualifier", "needs" => ["build"]},
          "review" => %{"role" => "reviewer", "needs" => ["spec"]}
        }
      }
    end

    # Producer-TERMINAL map (brief-gate style): the last step is a producer (build/engineer);
    # there is NO `review`/`merged` step (those are PR lifecycle stages set POST-map).
    def load!("gate-terminal") do
      %{
        "name" => "gate-terminal",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
    end

    def load!(_), do: raise("workflow_map not found")
  end

  # ForgeClient seam (②.1c): the judge resolves the producer branch via the issue's open PR
  # (without a workflow_map). Stub = one open PR for issue 42, head = the producer's branch.
  defmodule StubForge do
    def list_open_pulls(_repo, _opts) do
      {:ok, [%{"number" => 7, "head" => %{"ref" => "lcars/issue-42-engineer"}}]}
    end
  end

  # deliverable_mode seam: engineer = git_native (producer), everything else = payload (judge).
  defp dmode,
    do: fn
      "engineer" -> {:ok, "git_native"}
      _ -> {:ok, "payload"}
    end

  defp state(extra \\ %{}) do
    Map.merge(
      %StepRunConsumer{
        repo: "lordzurp/lcars-test",
        remote: "origin",
        forge_opts: [base_url: "http://10.42.0.118"],
        role_emails: fn role -> ["#{role}@lcars.local"] end,
        step_run_completer: CaptureCompleter,
        deliverable_mode_fun: dmode()
      },
      extra
    )
  end

  defp step_payload(extra \\ %{}) do
    Map.merge(
      %{
        "pod_id" => "pod-abc",
        "issue_id" => "issue-42",
        "result" => %{"ok" => true},
        "workspace" => "/pods/pod-abc/workspace",
        "base_sha" => "cafe1234",
        "role" => "engineer"
      },
      extra
    )
  end

  describe "maybe_complete/2 — event -> PR-native step_run translation" do
    test "project-bearing engineer pod (A1 single-brick) -> producer step_run, intent :review (②.1d)" do
      # ②.1d: without a workflow_map, the producer no longer merges directly (:promote) — it opens
      # the PR and REQUESTS the judges (:review). The merge is then driven by the PR-state
      # (dispatch_review).
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(step_payload(), state())

      assert_received {:step_run, step_run, opts}
      assert step_run.repo == "lordzurp/lcars-test"
      assert step_run.issue_number == 42
      assert step_run.role == "engineer"
      assert step_run.pr_role == :producer
      assert step_run.intent == :review
      assert step_run.next_assignee == nil
      assert step_run.producer_branch == "lcars/issue-42-engineer"
      assert step_run.base_branch == "main"

      d = step_run.deliverable_opts
      assert d.mode == :git_native
      assert d.workspace == "/pods/pod-abc/workspace"
      assert d.base_sha == "cafe1234"
      assert d.allowed_emails == ["engineer@lcars.local"]
      assert d.remote == "origin"
      assert d.target_branch == "lcars/issue-42-engineer"
      assert d.push? == true

      assert opts[:forge_opts] == [base_url: "http://10.42.0.118"]
    end

    test "producer: result.summary -> step_run.eng_summary (the eng's voice, OUTGOING info)" do
      payload =
        step_payload(%{"result" => %{"ok" => true, "summary" => "j'ai fait X, choisi Y"}})

      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())
      assert_received {:step_run, step_run, _}
      assert step_run.eng_summary == "j'ai fait X, choisi Y"
    end

    test "producer: non-string summary -> coerced safe_str (no singleton crash #8); absent -> no key" do
      # map -> inspect (defensive coercion: an LLM may return an object)
      p = step_payload(%{"result" => %{"summary" => %{"raw" => 1}}})
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(p, state())
      assert_received {:step_run, step_run, _}
      assert step_run.eng_summary =~ "raw"
      # without summary -> no eng_summary key (no empty voice)
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(step_payload(), state())
      assert_received {:step_run, hop2, _}
      refute Map.has_key?(hop2, :eng_summary)
    end

    test "BLOCKED producer (result.blocked) -> await_arch (motive=summary), NOT complete_pr (anti-wedge)" do
      payload =
        step_payload(%{
          "result" => %{"blocked" => true, "summary" => "Manque la spec du protocole X"}
        })

      assert {:ok, :awaiting_arch} = StepRunConsumer.maybe_complete(payload, state())

      # human escalation, not an empty publish (which would wedge :no_deliverable_commit)
      assert_received {:await_arch, step_run, _opts}
      refute_received {:step_run, _, _}
      assert step_run.issue_number == 42
      assert step_run.role == "engineer"
      assert step_run.decision == :blocked_dep
      # "BLOQUÉ" pins the FR user-facing comment body; the summary flows into it verbatim.
      assert step_run.comment_body =~ "BLOQUÉ"
      assert step_run.comment_body =~ "Manque la spec du protocole X"
    end

    test "blocked only for a PRODUCER (a judge with blocked goes through the normal path)" do
      # reviewer = judge (deliverable_mode payload) → blocked ignored, normal path (step_run captured).
      payload =
        step_payload(%{"role" => "reviewer", "result" => %{"blocked" => true}})

      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())
      assert_received {:step_run, _step_run, _}
      refute_received {:await_arch, _, _}
    end
  end

  describe "F067 — completion offload (step_run_runner)" do
    test "async step_run_runner -> completion offloaded (the singleton does not block on .complete_pr)" do
      test_pid = self()

      # "Recording" runner: captures the exec without launching it (simulates the Task.Supervisor
      # offload) -> proves .complete_pr goes through the runner, not directly (blocking) in the
      # GenServer.
      recording = fn exec ->
        send(test_pid, {:offloaded, exec})
        {:ok, :offloaded}
      end

      assert {:ok, :offloaded} =
               StepRunConsumer.maybe_complete(
                 step_payload(),
                 state(%{step_run_runner: recording})
               )

      assert_received {:offloaded, exec}

      # the captured exec, when run, does the REAL completion (CaptureCompleter -> {:step_run,...} + {:ok,:captured}).
      assert {:ok, :captured} = exec.()
      assert_received {:step_run, _step_run, _opts}
    end
  end

  describe "maybe_complete/2 — filters (skip)" do
    test "pipeline pod (workflow_map_id present) -> skip, no completer call" do
      payload = step_payload(%{"workflow_map_id" => "pl-1", "step" => "build"})
      assert {:skip, :workflow_map_pod} = StepRunConsumer.maybe_complete(payload, state())
      refute_received {:step_run, _, _}
    end

    test "pod without project (no base_sha) -> skip" do
      payload = step_payload(%{"base_sha" => nil, "workspace" => nil})
      assert {:skip, :no_project} = StepRunConsumer.maybe_complete(payload, state())
      refute_received {:step_run, _, _}
    end

    test "empty base_sha -> skip (no git deliverable)" do
      payload = step_payload(%{"base_sha" => ""})
      assert {:skip, :no_project} = StepRunConsumer.maybe_complete(payload, state())
    end

    test "unparseable issue_id -> skip" do
      payload = step_payload(%{"issue_id" => "owner/repo#42"})

      assert {:skip, {:bad_issue_id, "owner/repo#42"}} =
               StepRunConsumer.maybe_complete(payload, state())
    end
  end

  describe "A2.4 — workflow_map chaining (pipeline+step -> intent + pr_role)" do
    test "producer middle step (build/engineer, gate pass) -> :advance to qualifier" do
      payload = step_payload(%{"workflow_map" => "poc-cycle", "step" => "build"})

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      assert_received {:step_run, step_run, _opts}
      assert step_run.pr_role == :producer
      assert step_run.intent == :advance
      # build -> spec (role qualifier)
      assert step_run.next_assignee == "qualifier"
      assert step_run.producer_branch == "lcars/issue-42-engineer"
    end

    test "judge last step (review/reviewer) -> terminal :promote, producer's branch" do
      payload =
        step_payload(%{"role" => "reviewer", "workflow_map" => "poc-cycle", "step" => "review"})

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(
                 payload,
                 state(%{loader: StubLoader, forge_client: StubForge})
               )

      assert_received {:step_run, step_run, _opts}
      assert step_run.pr_role == :judge
      assert step_run.intent == :promote
      assert step_run.next_assignee == nil

      # the judge reviews the producer's PR, resolved without a workflow_map via the open PR (head=producer)
      assert step_run.producer_branch == "lcars/issue-42-engineer"
      # a judge carries no deliverable_opts (it does not push)
      refute Map.has_key?(step_run, :deliverable_opts)
    end

    test "F-E8: NO-WORKFLOW_MAP judge with inherited route (role != step's role) -> :reviewed, NEVER :promote" do
      # Live bug PoC-7: the qualifier (no-workflow_map judge dispatched on the PR) INHERITS the
      # issue's route (step `build`, role engineer). Without the `step_role_matches?` guard,
      # gate_decide(build) saw it as terminal NON-producer -> :promote -> MERGE on 1 judge (quorum
      # short-circuited). With it: role `qualifier` != step `build`'s role -> no-workflow_map
      # resolution -> :reviewed (records the review; the merge belongs to the
      # `dispatch_by_verdicts` quorum which waits for ALL judges).
      payload =
        step_payload(%{"role" => "qualifier", "workflow_map" => "poc-cycle", "step" => "build"})

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(
                 payload,
                 state(%{loader: StubLoader, forge_client: StubForge})
               )

      assert_received {:step_run, step_run, _opts}
      assert step_run.pr_role == :judge
      assert step_run.intent == :reviewed
    end

    test "LIFECYCLE stage (review) inherited on a producer-terminal map -> :reviewed, NOT unknown_step" do
      # WS2 regression: `stage/review` is set POST-map (open_deliverable_pr); get_route then returns
      # step=`review`, which IS NOT a step of the producer-terminal map `gate-terminal`. Without the
      # `lifecycle_stage?` guard, resolve_next fell into `next_step(map, "review")` ->
      # {:workflow_map_nav, :unknown_step} (the PR judge looped, re-spawned forever, never merged).
      # A lifecycle stage absent from the map -> no-workflow_map resolution -> :reviewed (the merge
      # belongs to the dispatch_review quorum).
      payload =
        step_payload(%{
          "role" => "qualifier",
          "workflow_map" => "gate-terminal",
          "step" => "review"
        })

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(
                 payload,
                 state(%{loader: StubLoader, forge_client: StubForge})
               )

      assert_received {:step_run, step_run, _opts}
      assert step_run.pr_role == :judge
      assert step_run.intent == :reviewed
    end

    test "workflow_map not found -> {:error, {:workflow_map_load_failed, ..}}, no step_run" do
      payload = step_payload(%{"workflow_map" => "bad", "step" => "build"})

      assert {:error, {:workflow_map_load_failed, _, _}} =
               StepRunConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      refute_received {:step_run, _, _}
    end

    test "unknown step in the workflow_map -> {:error, {:workflow_map_nav, :unknown_step}}, no misroute" do
      payload = step_payload(%{"workflow_map" => "poc-cycle", "step" => "ghost"})

      assert {:error, {:workflow_map_nav, :unknown_step}} =
               StepRunConsumer.maybe_complete(payload, state(%{loader: StubLoader}))

      refute_received {:step_run, _, _}
    end

    test "without workflow_map context (A1 single-brick) -> producer :review, no (workflow_map) loader call" do
      # (workflow_map) loader nil: if run_step_run called the workflow_map loader without workflow_map
      # context, it would crash. The no-workflow_map path calls deliverable_mode_fun (dmode), not the
      # workflow_map loader.
      payload = step_payload()
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())
      assert_received {:step_run, step_run, _opts}
      assert step_run.intent == :review
      assert step_run.next_assignee == nil
    end

    test "without workflow_map, a JUDGE (payload role) -> :reviewed + review_event mapped from the gate-decision (②.1d)" do
      # role "qualifier" => dmode = "payload" => judge. The pod's verdict (gate-decision) is mapped
      # to a review event: continue->approve; EVERYTHING else->request_changes (DECISIVE
      # fail-closed: a non-decisive COMMENT would make the judge loop, verified live #6).
      for {decision, event} <- [
            {"continue", :approve},
            {"abandon", :request_changes},
            {"halt_wait_input", :request_changes},
            {"garbage_unparseable", :request_changes}
          ] do
        # `reason` present (F-C161: required) → only the DECISION distinguishes the cases;
        # `garbage_unparseable` stays halt_invalid via the enum, not via the motive.
        payload =
          step_payload(%{
            "role" => "qualifier",
            "result" => %{"decision" => decision, "reason" => "some reason"}
          })

        # forge_client: StubForge → the judge resolves the producer branch via the open PR (no HTTP).
        assert {:ok, :captured} =
                 StepRunConsumer.maybe_complete(payload, state(%{forge_client: StubForge}))

        assert_received {:step_run, step_run, _opts}
        assert step_run.pr_role == :judge
        assert step_run.intent == :reviewed
        assert step_run.review_event == event
        assert step_run.producer_branch == "lcars/issue-42-engineer"
        refute Map.has_key?(step_run, :deliverable_opts)
      end
    end

    test "review-body robust to mistyped LLM outputs (live regression #8: non-string chain crashed)" do
      # A judge may return reason/chain/details as nested objects/lists. A raw `#{...}` crashed the
      # StepRunConsumer (SINGLETON) → end-of-step-run lost → lock never lifted → wedged pipe.
      # `safe_str` must absorb without crashing and produce a string review body.
      payload =
        step_payload(%{
          "role" => "qualifier",
          "result" => %{
            "decision" => "abandon",
            "reason" => %{"resume" => "an object, not a string"},
            "chain" => [%{"step" => "reading"}, ["nested", "list"], 42],
            "details" => %{"critere" => %{"nested" => true}}
          }
        })

      assert {:ok, :captured} =
               StepRunConsumer.maybe_complete(payload, state(%{forge_client: StubForge}))

      assert_received {:step_run, step_run, _opts}
      assert step_run.review_event == :request_changes
      assert is_binary(step_run.review_body)
      # "CHANGEMENTS DEMANDÉS" pins the FR user-facing review body.
      assert step_run.review_body =~ "CHANGEMENTS DEMANDÉS"
    end
  end

  describe "parse_issue_number/1" do
    test "issue-N -> {:ok, N}" do
      assert {:ok, 7} = StepRunConsumer.parse_issue_number("issue-7")
    end

    test "legacy / unknown format -> :error" do
      assert :error = StepRunConsumer.parse_issue_number("owner/repo#7")
      assert :error = StepRunConsumer.parse_issue_number("issue-7x")
      assert :error = StepRunConsumer.parse_issue_number("issue-")
    end
  end

  describe "F-037 — per-step-run repo + remote (derived from the event)" do
    test "repo-bearing payload → step_run.repo + deliverable.remote come from the EVENT, not the config" do
      # MULTI-PROJECT: the StepRunConsumer singleton handles N projects. THIS step_run's repo
      # (forge API) and remote (push) come from the `pod.completed` (the Spawner embeds them), NOT
      # from the config fallback.
      payload =
        step_payload(%{
          "repository" => %{"full_name" => "alice/proj-a"},
          "remote" => "http://forge/alice/proj-a.git"
        })

      # deliberately DIFFERENT config state (repo "lordzurp/lcars-test", remote "origin") → if the
      # step_run read the config instead of the event, the assertion would break.
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())

      assert_received {:step_run, step_run, _opts}
      assert step_run.repo == "alice/proj-a"
      assert step_run.deliverable_opts.remote == "http://forge/alice/proj-a.git"
      # the system branch stays derived from the issue (repo-local, unscoped)
      assert step_run.producer_branch == "lcars/issue-42-engineer"
    end

    test "payload WITHOUT repo → config fallback (single-repo legacy / bare-payload test)" do
      # Backward compat: a `pod.completed` that does not carry its repo → the StepRunConsumer falls
      # back to its config repo/remote (the path of ALL pre-F-037 tests).
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(step_payload(), state())
      assert_received {:step_run, step_run, _opts}
      assert step_run.repo == "lordzurp/lcars-test"
      assert step_run.deliverable_opts.remote == "origin"
    end
  end

  describe "GenServer lifecycle" do
    test "F-037: init WITHOUT :repo/:remote succeeds (per-step-run, no boot-time require anymore)" do
      # The :repo/:remote opts are no longer mandatory (repo+remote come from the event). A
      # multi-project boot (without a fixed repo) is legitimate; the rail's fail-loud guard lives in
      # application.ex.
      name = :"HC_norepo_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        StepRunConsumer.start_link(
          name: name,
          subscribe: false,
          gatekeeper_boot_fun: fn -> {:ok, :disabled} end
        )

      assert Process.alive?(pid)
      assert %StepRunConsumer{repo: nil, remote: nil} = :sys.get_state(pid)

      GenServer.stop(pid)
    end

    test "F067: start_link wires :step_run_runner -> completion goes through the runner (init/prod path)" do
      # RED-first: this test goes through start_link -> init (the PROD path, which step_children
      # uses), NOT a directly built state. If init forgets to read :step_run_runner from the opts,
      # the injected runner is ignored -> the completion runs sync (blocking) -> {:offloaded_gs}
      # NEVER arrives -> this test fails. It is the safety net of the F067-init critique.
      test_pid = self()

      recording = fn exec ->
        send(test_pid, {:offloaded_gs, exec})
        {:ok, :offloaded}
      end

      name = :"HC_runner_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        StepRunConsumer.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          remote: "origin",
          forge_opts: [base_url: "http://10.42.0.118"],
          role_emails: fn role -> ["#{role}@lcars.local"] end,
          step_run_completer: CaptureCompleter,
          deliverable_mode_fun: dmode(),
          step_run_runner: recording,
          subscribe: false
        )

      send(
        pid,
        Fleet.Event.new(:spawner, :"pod.completed", pod_id: "pod-abc", payload: step_payload())
      )

      # init wired step_run_runner -> the completion is routed to the runner (msg to the test process).
      assert_receive {:offloaded_gs, _exec}, 1_000
    end

    test "handle_info pod.completed -> delegates (via real Event, subscribe: false)" do
      name = :"HC_live_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        StepRunConsumer.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          remote: "origin",
          step_run_completer: CaptureCompleter,
          deliverable_mode_fun: dmode(),
          subscribe: false
        )

      # The completer does send(self()) INSIDE the GenServer -> we just verify the event is routed
      # without crash (the step_run is unit-tested via maybe_complete).
      event =
        Fleet.Event.new(:spawner, :"pod.completed", pod_id: "pod-abc", payload: step_payload())

      send(pid, event)
      assert Process.alive?(pid)
      # a non-spawner event is ignored without crash
      send(pid, Fleet.Event.new(:task_queue, :"work_item.completed"))

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "work_item.completed of an arch escalation (metadata awaits_arch) → DRAINS lcars-awaits-arch" do
      # Serialize-via-forge: the arch resolved its mandate (submit_result) → the system removes the
      # waiting label so the poller serves the NEXT one. The repo+number travel in the work-item's
      # metadata (the WorkItem has no repo field). `forge_opts[:test_pid]` carries the pid for the
      # cross-process assertion (the stub runs INSIDE the GenServer).
      defmodule DrainForge do
        def remove_label(repo, number, label, opts) do
          send(opts[:test_pid], {:remove_label, repo, number, label})
          {:ok, :removed}
        end
      end

      name = :"HC_drain_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        StepRunConsumer.start_link(
          name: name,
          forge_client: DrainForge,
          forge_opts: [test_pid: self()],
          subscribe: false
        )

      arch_done =
        Fleet.Event.new(:task_queue, :"work_item.completed",
          correlation_id: "wi-arch-1",
          payload: %{metadata: %{"awaits_arch" => true, "repo" => "fleet/proj", "number" => 7}}
        )

      send(pid, arch_done)
      assert_receive {:remove_label, "fleet/proj", 7, "lcars-awaits-arch"}, 1_000

      # a NON-arch completion (no `awaits_arch`) drains NOTHING (nominal path preserved).
      other_done =
        Fleet.Event.new(:task_queue, :"work_item.completed",
          correlation_id: "wi-other",
          payload: %{metadata: %{"gate_eval" => false}}
        )

      send(pid, other_done)
      refute_receive {:remove_label, _, _, _}, 200

      GenServer.stop(pid)
    end
  end

  describe "default_deliverable_mode/1 (DR-013 — unloadable role ≠ absent)" do
    test "LOADABLE role → {:ok, mode} (the cap-profile's deliverable_mode)" do
      # engineer is a canon role → loadable → producer (git_native).
      assert {:ok, "git_native"} = StepRunConsumer.default_deliverable_mode("engineer")
    end

    test "DR-013: UNLOADABLE role (missing/corrupt profile) → {:error, :cap_profile_unloadable} + LOUD log" do
      # Core of the finding: an unloadable profile is a config PROBLEM. A silent "payload" fallback
      # → `producer?` read it as non-producer → SILENTLY reclassified as a judge (a real producer,
      # its code never pushed). Instead: CLOSED RESULT `{:error, :cap_profile_unloadable}` → the
      # producer/judge classification fails loud (never consumed as "judge" by default).
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :cap_profile_unloadable} =
                   StepRunConsumer.default_deliverable_mode(
                     "role-inexistant-#{System.unique_integer([:positive])}"
                   )
        end)

      assert log =~ "UNLOADABLE"
    end
  end
end
