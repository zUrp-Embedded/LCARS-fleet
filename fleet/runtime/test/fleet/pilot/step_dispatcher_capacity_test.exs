defmodule Fleet.Pilot.StepDispatcherCapacityTest do
  @moduledoc """
  Regression acte4 A-11 — PRE-FLIGHT capacity gate (before the forge lock). At saturation
  (`max_pods`), taking the lock first would discover `:max_children` at spawn, then compensate
  (unlock) EVERY tick: ~4 forge writes/issue/30s polluting the timeline, and "full" tallied as an
  ERROR (poller backoff as if the forge were failing). The pre-flight gate defers WITHOUT any
  write (`{:skipped, :at_capacity}`); the residual TOCTOU stays covered by `max_children` + the
  compensation (now the rare exception).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher
  alias Fleet.Pilot.StepDispatcher.Spawn
  alias Fleet.Pilot.StubTaskQueue

  defmodule CaptureForge do
    def add_label(_repo, _n, label, _opts) do
      send(self(), {:add_label, label})
      {:ok, :added}
    end

    def remove_label(_repo, _n, label, _opts) do
      send(self(), {:remove_label, label})
      {:ok, :removed}
    end

    def start_stopwatch(_repo, _n, _opts), do: :ok
    def stop_stopwatch(_repo, _n, _opts), do: :ok
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)
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
  end

  # Saturated + fresh pod: has_capacity? false, pod_info :error (pod not alive).
  defmodule FullFreshSpawner do
    def has_capacity?, do: false
    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: raise("spawn_pod must NEVER be reached at saturation")
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # Saturated + ALIVE pod: the re-brief creates no child → must NOT be gated.
  defmodule FullAliveSpawner do
    def has_capacity?, do: false
    def pod_info(_pod_id), do: {:ok, %{phase: :monitoring}}
    def spawn_pod(_p, _i, _o), do: raise("a live pod gets re-briefed, no spawn")
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # TOCTOU: the free slot at check time is stolen before the spawn → :max_children at real spawn.
  defmodule ToctouSpawner do
    def has_capacity?, do: true
    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: {:error, :max_children}
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  defp profile do
    {:ok, p} = StubLoader.load("engineer")
    p
  end

  defp seams(spawner) do
    %Spawn.Seams{
      forge: CaptureForge,
      spawner: spawner,
      task_queue: StubTaskQueue,
      repo: "lordzurp/lcars-test",
      forge_opts: [],
      wake_recovery: fn _pod_id, _spawn_fn, _opts -> :ok end
    }
  end

  test "saturated + FRESH spawn → {:skipped, :at_capacity}, NO forge write (no lock)" do
    assert {:skipped, :at_capacity} =
             Spawn.spawn_step(
               seams(FullFreshSpawner),
               "pod-x",
               "engineer",
               profile(),
               "brief",
               [],
               42,
               42,
               "ctx"
             )

    refute_received {:add_label, _}
    refute_received {:remove_label, _}
  end

  test "saturated + ALIVE pod → the re-brief PROCEEDS (a live pipe creates no child: not starved)" do
    assert {:ok, {:spawned, "pod-alive", "engineer"}} =
             Spawn.spawn_step(
               seams(FullAliveSpawner),
               "pod-alive",
               "engineer",
               profile(),
               "brief",
               [],
               42,
               42,
               "ctx"
             )

    # the lock IS taken (the pod is working the issue), no kill/compensation
    assert_received {:add_label, "lcars-in-flight"}
    refute_received {:remove_label, _}
  end

  test "TOCTOU (slot stolen between check and spawn) → :max_children at spawn + compensation intact" do
    assert {:error, :max_children} =
             Spawn.spawn_step(
               seams(ToctouSpawner),
               "pod-t",
               "engineer",
               profile(),
               "brief",
               [],
               42,
               42,
               "ctx"
             )

    # the lock was taken THEN compensated (remove_label) — the TOCTOU net holds
    assert_received {:add_label, "lcars-in-flight"}
    assert_received {:remove_label, "lcars-in-flight"}
  end

  test "end-to-end propagation: dispatch_issue returns {:skipped, :at_capacity} (tally skip, not error)" do
    payload = %{
      "issue" => %{
        "number" => 42,
        "body" => "fais le hello",
        "labels" => [],
        "assignees" => [%{"login" => "lordzurp"}]
      }
    }

    opts = [
      repo: "lordzurp/lcars-test",
      forge_client: CaptureForge,
      forge_opts: [_test_route: {:ok, {"g", "build"}}],
      loader: StubLoader,
      spawner: FullFreshSpawner,
      task_queue: StubTaskQueue,
      project_resolver: fn _repo, _opts -> {:ok, nil} end,
      workflow_map_loader: fn _name ->
        %{
          "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
          "max_rework_rounds" => 2
        }
      end
    ]

    assert {:skipped, :at_capacity} = StepDispatcher.dispatch_issue(payload, opts)
    refute_received {:add_label, _}
  end
end
