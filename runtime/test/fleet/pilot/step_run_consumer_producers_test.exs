defmodule Fleet.Pilot.StepRunConsumerProducersTest do
  @moduledoc """
  Q2 DRAFT producers — `StepRunConsumer` feeds the incident rail:

  - `workflow_map.failed` — emitted on a workflow_map LOAD failure (`:workflow_map_load_failed`).

  Both are emitted with source `:workflow` (invariant anti-spoof du registre : la route exige sa source) via `safe_emit`:
  an emission failure is logged warning by the producer and never blocks the carrying escalation
  (the Bus is the lossy fast-path; durable truth stays on the forge rail).
  We subscribe to the REAL Bus (that is the point of the test: prove the emission) → `async: false`
  (shared global Bus state) + unique names/issues for hermeticity.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Pilot.StepRunConsumer
  alias Fleet.Pilot.StepRunConsumer.GateEngine

  # Loader: "bad-q2" raises (not found → :workflow_map_load_failed); "judgemap-q2" = 1 JUDGE step.
  defmodule Loader do
    def load!("judgemap-q2") do
      %{
        "name" => "judgemap-q2",
        "steps" => %{
          "gate" => %{
            "role" => "consultant",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "brief"
          }
        }
      }
    end

    def load!(_), do: raise("workflow_map not found")
  end

  # Completer: captures complete_pr + await_arch (freeze_to_arch → await_arch).
  defmodule CaptureCompleter do
    def complete_pr(step_run, opts) do
      send(self(), {:step_run, step_run, opts})
      {:ok, :captured}
    end

    def await_arch(step_run, opts) do
      send(self(), {:await_arch, step_run, opts})
      {:ok, :awaiting_arch}
    end
  end

  defmodule StubSpawner do
    def wake_pod(pod_id) do
      send(self(), {:wake, pod_id})
      :ok
    end
  end

  defp dmode,
    do: fn
      "engineer", _root -> {:ok, "git_native"}
      _, _root -> {:ok, "payload"}
    end

  defp state do
    %StepRunConsumer{
      repo: "o/r",
      remote: "origin",
      forge_opts: [],
      role_emails: fn r -> ["#{r}@lcars.local"] end,
      step_run_completer: CaptureCompleter,
      deliverable_mode_fun: dmode(),
      loader: Loader,
      spawner: StubSpawner,
      gate_evals: %{}
    }
  end

  setup do
    Bus.subscribe()
    :ok
  end

  describe "workflow_map.failed draft producer" do
    test "workflow_map LOAD failure → emits workflow_map.failed (source :workflow), rien d'autre" do
      payload = %{
        "issue_id" => "issue-42",
        "workspace" => "/ws",
        "base_sha" => "cafe",
        "role" => "engineer",
        "workflow_map" => "bad-q2",
        "step" => "build",
        "result" => %{}
      }

      assert {:error, {:workflow_map_load_failed, _, _}} =
               StepRunConsumer.maybe_complete(payload, state())

      assert_receive %Fleet.Event{
                       source: :workflow,
                       type: :"workflow_map.failed",
                       payload: %{
                         "workflow_map" => "bad-q2",
                         "issue" => 42,
                         "role" => "engineer",
                         "producer" => "draft:step_run_consumer"
                       }
                     },
                     500

      # Targeted rail: one failure, one event — nothing else broadcast.
      refute_received %Fleet.Event{type: :"incident.escalated"}
    end
  end

  describe "DR-013 — unreadable cap-profile at completion → escalation, never a silent judge" do
    test "deliverable_mode_fun {:error, :cap_profile_unloadable} → arch freeze (await_arch), NO silent completion" do
      # A role whose cap-profile has vanished/corrupted since the spawn: the producer/judge mode is
      # UNKNOWN. A "payload" fallback → producer? false → SILENTLY reclassified as a judge
      # (a real producer, its code never pushed). DR-013 instead: {:error} → fail-loud + escalate to
      # the arch (freeze_to_arch: never bubble → the reaper would re-dispatch a broken profile
      # forever, G2 churn).
      st = %{
        state()
        | deliverable_mode_fun: fn _role, _root -> {:error, :cap_profile_unloadable} end
      }

      payload = %{
        "issue_id" => "issue-77",
        "workspace" => "/ws",
        "base_sha" => "cafe",
        "role" => "engineer",
        "workflow_map" => "judgemap-q2",
        "step" => "gate",
        "result" => %{}
      }

      StepRunConsumer.maybe_complete(payload, st)

      # Human escalation (freeze_to_arch → await_arch), NEVER a silent completion as a judge.
      assert_receive {:await_arch, _step_run, _opts}, 500
      refute_received {:step_run, _, _}
    end
  end

  describe "the effective deliverable_mode travels, it is not re-derived from the base role" do
    test "producer?/3 prefers the payload's effective mode → the base-role seam is NOT consulted" do
      # The pod ran a RESOLVED profile whose deliverable_mode is carried in the pod.completed payload.
      # The completion consumes THAT — a since-vanished/edited base profile (the DR-013 trigger) is
      # irrelevant when the effective fact already travelled. The seam MUST NOT be called.
      raising = fn _role, _root ->
        raise "deliverable_mode_fun must not be consulted when the payload carries the mode"
      end

      assert {:ok, true} = GateEngine.producer?("engineer", raising, "git_native")
      assert {:ok, false} = GateEngine.producer?("qualifier", raising, "payload")
    end

    test "producer?/3 with nil effective mode falls back to the seam (DR-013 fail-loud preserved)" do
      # Bare/legacy payload (no `deliverable_mode`) → re-derive from the base role via the seam, keeping
      # the DR-013 closed classification: {:ok, _} resolves, {:error, _} fails loud (never a silent judge).
      assert {:ok, true} =
               GateEngine.producer?("engineer", fn _, _ -> {:ok, "git_native"} end, nil)

      assert {:ok, false} =
               GateEngine.producer?("qualifier", fn _, _ -> {:ok, "payload"} end, nil)

      assert {:error, :cap_profile_unloadable} =
               GateEngine.producer?(
                 "engineer",
                 fn _, _ -> {:error, :cap_profile_unloadable} end,
                 nil
               )
    end
  end
end
