defmodule Fleet.Pilot.StepRunConsumerTest do
  use ExUnit.Case, async: true
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.StepRunConsumer

  defmodule CaptureCompleter do
    def complete_pr(step_run, opts) do
      # Direct calls send to the test; GenServer calls need the registered observer to reach it.
      send(self(), {:step_run, step_run, opts})

      if obs = Process.whereis(:step_run_delegation_observer),
        do: send(obs, {:delegated, step_run})

      {:ok, :captured}
    end

    def await_arch(step_run, opts) do
      send(self(), {:await_arch, step_run, opts})
      {:ok, :awaiting_arch}
    end
  end

  # Linear loaded card; unknown names raise.
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

    # review/merged are lifecycle stages absent from this producer-terminal map.
    def load!("gate-terminal") do
      %{
        "name" => "gate-terminal",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
    end

    def load!(_), do: raise("workflow_map not found")
  end

  # One open producer PR for issue 42, independent of map position.
  defmodule StubForge do
    def list_open_pulls(_repo, _opts) do
      {:ok, [PayloadFixture.pull(number: 7, head_ref: "lcars/issue-42-engineer")]}
    end
  end

  defp dmode,
    do: fn
      "engineer", _root -> {:ok, "git_native"}
      _, _root -> {:ok, "payload"}
    end

  defp state(extra \\ %{}) do
    Map.merge(
      %StepRunConsumer{
        repo: "lordzurp/lcars-test",
        remote: "origin",
        forge_opts: [base_url: "http://192.0.2.10"],
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
        "base_branch" => "main",
        "role" => "engineer"
      },
      extra
    )
  end

  describe "maybe_complete/2 — event -> PR-native step_run translation" do
    test "project-bearing engineer pod (A1 single-brick) -> producer step_run, intent :review (②.1d)" do
      # A card-less producer enters PR review; this translation does not perform promotion.
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

      assert opts[:forge_opts] == [base_url: "http://192.0.2.10"]
    end

    test "producer: result.summary -> step_run.eng_summary (the eng's voice, OUTGOING info)" do
      payload =
        step_payload(%{"result" => %{"ok" => true, "summary" => "j'ai fait X, choisi Y"}})

      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())
      assert_received {:step_run, step_run, _}
      assert step_run.eng_summary == "j'ai fait X, choisi Y"
    end

    test "producer: non-string summary -> coerced safe_str (no singleton crash #8); absent -> no key" do
      p = step_payload(%{"result" => %{"summary" => %{"raw" => 1}}})
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(p, state())
      assert_received {:step_run, step_run, _}
      assert step_run.eng_summary =~ "raw"

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

      assert_received {:await_arch, step_run, _opts}
      refute_received {:step_run, _, _}
      assert step_run.issue_number == 42
      assert step_run.role == "engineer"
      assert step_run.decision == :blocked_dep

      assert step_run.comment_body =~ "BLOQUÉ"
      assert step_run.comment_body =~ "Manque la spec du protocole X"
    end

    test "blocked only for a PRODUCER (a judge with blocked goes through the normal path)" do
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

      # Capture the deferred closure without launching a Task or measuring GenServer latency.
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

      # Executing the closure calls the captured completer, not a real forge completion.
      assert {:ok, :captured} = exec.()
      assert_received {:step_run, _step_run, _opts}
    end

    test "an arity-2 runner receives the completion META (pod_id + issue) — BL-6-03 S2" do
      test_pid = self()

      recording = fn exec, meta ->
        send(test_pid, {:offloaded, exec, meta})
        {:ok, :offloaded}
      end

      assert {:ok, :offloaded} =
               StepRunConsumer.maybe_complete(
                 step_payload(),
                 state(%{step_run_runner: recording})
               )

      # Pod/issue metadata identifies publish loss if the offloaded task dies.
      assert_received {:offloaded, _exec, %{pod_id: "pod-abc", issue: 42}}
    end

    test "the death of an offloaded completion with a pod meta emits deliverable.publish_lost (BL-6-03 S2)" do
      # Reuse or start the global supervisor; this test does not isolate it from concurrent callers.
      unless Process.whereis(Fleet.Pilot.StepRunTaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Fleet.Pilot.StepRunTaskSupervisor})
      end

      Fleet.EventRouter.Bus.subscribe()
      test = self()

      # The task waits for release so monitoring precedes its intentional exit.
      {:ok, :offloaded} =
        StepRunConsumer.offload_async(
          fn ->
            send(test, {:task_pid, self()})

            receive do
              :go -> exit(:boom)
            end
          end,
          %{pod_id: "pod-s2", issue: 9}
        )

      assert_receive {:task_pid, task_pid}, 1_000
      send(task_pid, :go)

      # offload_async installed its monitor in this test process; feed DOWN to the handler directly.
      assert_receive {:DOWN, _, :process, _, :boom} = down, 1_000

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:noreply, %{}} = StepRunConsumer.handle_info(down, %{})
      end)

      assert_receive %Fleet.Event{
                       type: :"deliverable.publish_lost",
                       pod_id: "pod-s2",
                       correlation_id: "9",
                       payload: %{"reason" => reason}
                     },
                     1_000

      assert reason =~ "boom"
    end

    test "a meta-less offloaded death emits NOTHING (no pod waits on those paths)" do
      unless Process.whereis(Fleet.Pilot.StepRunTaskSupervisor) do
        start_supervised!({Task.Supervisor, name: Fleet.Pilot.StepRunTaskSupervisor})
      end

      Fleet.EventRouter.Bus.subscribe()
      test = self()

      {:ok, :offloaded} =
        StepRunConsumer.offload_async(fn ->
          send(test, {:task_pid, self()})

          receive do
            :go -> exit(:boom)
          end
        end)

      assert_receive {:task_pid, task_pid}, 1_000
      send(task_pid, :go)
      assert_receive {:DOWN, _, :process, _, :boom} = down, 1_000

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:noreply, %{}} = StepRunConsumer.handle_info(down, %{})
      end)

      refute_receive %Fleet.Event{type: :"deliverable.publish_lost"}, 100
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

      # Resolve the producer's branch through the open PR lookup.
      assert step_run.producer_branch == "lcars/issue-42-engineer"

      refute Map.has_key?(step_run, :deliverable_opts)
    end

    test "F-E8: NO-WORKFLOW_MAP judge with inherited route (role != step's role) -> :reviewed, NEVER :promote" do
      # A PR judge inheriting the producer's route must not use that map step to bypass the jury.
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
      # A lifecycle review stage absent from the map uses card-less review completion,
      # rather than navigating an unknown map step.
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
      # With no card context, the nil map loader is unused; role classification still runs.
      payload = step_payload()
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())
      assert_received {:step_run, step_run, _opts}
      assert step_run.intent == :review
      assert step_run.next_assignee == nil
    end

    test "without workflow_map, a JUDGE (payload role) -> :reviewed + review_event mapped from the gate-decision (②.1d)" do
      # Only a valid continue maps to approve; other decisions request changes.
      for {decision, event} <- [
            {"continue", :approve},
            {"abandon", :request_changes},
            {"halt_wait_input", :request_changes},
            {"garbage_unparseable", :request_changes}
          ] do
        # Keep reason valid so the unknown-decision case fails vocabulary validation.
        payload =
          step_payload(%{
            "role" => "qualifier",
            "result" => %{"decision" => decision, "reason" => "some reason"}
          })

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
      # Render malformed nested data safely while producing a refusing review event.
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
      # Event repository/remote must override a different configured fallback.
      payload =
        step_payload(%{
          "repository" => %{"full_name" => "alice/proj-a"},
          "remote" => "http://forge/alice/proj-a.git"
        })

      assert {:ok, :captured} = StepRunConsumer.maybe_complete(payload, state())

      assert_received {:step_run, step_run, _opts}
      assert step_run.repo == "alice/proj-a"
      assert step_run.deliverable_opts.remote == "http://forge/alice/proj-a.git"

      assert step_run.producer_branch == "lcars/issue-42-engineer"
    end

    test "payload WITHOUT repo → config fallback (single-repo legacy / bare-payload test)" do
      assert {:ok, :captured} = StepRunConsumer.maybe_complete(step_payload(), state())
      assert_received {:step_run, step_run, _opts}
      assert step_run.repo == "lordzurp/lcars-test"
      assert step_run.deliverable_opts.remote == "origin"
    end
  end

  describe "GenServer lifecycle" do
    test "F-037: init WITHOUT :repo/:remote succeeds (per-step-run, no boot-time require anymore)" do
      # Boot can omit fixed repo/remote; this test does not validate a later payload.
      name = :"HC_norepo_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        StepRunConsumer.start_link(
          name: name,
          subscribe: false
        )

      assert Process.alive?(pid)
      assert %StepRunConsumer{repo: nil, remote: nil} = settle(pid)

      GenServer.stop(pid)
    end

    test "F067: start_link wires :step_run_runner -> completion goes through the runner (init/prod path)" do
      # Exercise option wiring through start_link/init, not only a manually built state.
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
          forge_opts: [base_url: "http://192.0.2.10"],
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

      assert_receive {:offloaded_gs, _exec}, 1_000
    end

    test "handle_info pod.completed -> delegates (via real Event, subscribe: false)" do
      name = :"HC_live_#{System.unique_integer([:positive])}"

      # Register an observer for the completer effect from the GenServer.
      Process.register(self(), :step_run_delegation_observer)

      {:ok, pid} =
        StepRunConsumer.start_link(
          name: name,
          repo: "lordzurp/lcars-test",
          remote: "origin",
          step_run_completer: CaptureCompleter,
          deliverable_mode_fun: dmode(),
          subscribe: false
        )

      event =
        Fleet.Event.new(:spawner, :"pod.completed", pod_id: "pod-abc", payload: step_payload())

      send(pid, event)

      # Settle after the same sender's event before checking its observed delegation.
      _ = settle(pid)
      assert_received {:delegated, step_run}
      assert step_run.issue_number == 42

      # An unrelated task-queue event is handled without killing the consumer.
      send(pid, Fleet.Event.new(:task_queue, :"work_item.completed"))
      _ = settle(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "default_deliverable_mode/1 (DR-013 — unloadable role ≠ absent)" do
    test "LOADABLE role → {:ok, mode} (the cap-profile's deliverable_mode)" do
      assert {:ok, "git_native"} = StepRunConsumer.default_deliverable_mode("engineer")
    end

    test "DR-013: UNLOADABLE role (missing/corrupt profile) → {:error, :cap_profile_unloadable} + LOUD log" do
      # An unresolved profile must not default to payload mode and lose a producer's publication.
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
