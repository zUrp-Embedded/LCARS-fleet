defmodule Fleet.Pilot.StepRunConsumerProducersTest do
  @moduledoc """
  Exercises workflow_map.failed delivery through the real Bus, plus classification and
  architect-escalation seams. Serial for shared bus state; no durable incident consumer
  or forge persistence is verified. Emission failure handling is outside these cases.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus
  alias Fleet.Pilot.StepRunConsumer
  alias Fleet.Pilot.StepRunConsumer.GateEngine

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

      # Refutes incident.escalated specifically, not every possible additional event.
      refute_received %Fleet.Event{type: :"incident.escalated"}
    end
  end

  describe "DR-013 — unreadable cap-profile at completion → escalation, never a silent judge" do
    test "deliverable_mode_fun {:error, :cap_profile_unloadable} → arch freeze (await_arch), NO silent completion" do
      # A failed classification must escalate instead of treating a possible producer as a judge.
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

      assert_receive {:await_arch, _step_run, _opts}, 500
      refute_received {:step_run, _, _}
    end
  end

  describe "the effective deliverable_mode travels, it is not re-derived from the base role" do
    test "producer?/3 prefers the payload's effective mode → the base-role seam is NOT consulted" do
      # Explicit effective mode must bypass a potentially changed/unavailable base-role resolver.
      raising = fn _role, _root ->
        raise "deliverable_mode_fun must not be consulted when the payload carries the mode"
      end

      assert {:ok, true} = GateEngine.producer?("engineer", raising, "git_native")
      assert {:ok, false} = GateEngine.producer?("qualifier", raising, "payload")
    end

    test "producer?/3 with nil effective mode falls back to the seam (DR-013 fail-loud preserved)" do
      # Without effective mode, retain the resolver's explicit success/error result.
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
