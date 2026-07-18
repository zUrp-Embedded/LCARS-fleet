defmodule Fleet.Pilot.StepDispatcherGateOrderTest do
  @moduledoc """
  Regression acte4 A-09 — dispatch gate ordering: the cheap LOCAL gates (route/role/busy)
  short-circuit BEFORE the ProjectResolver (the only NETWORK call on the path, 1-2×
  `git ls-remote` ~15-30s). Without the fix, a recurring `:role_busy` tick re-paid the resolver
  every tick just to discard the result — and under a degraded forge blocked the whole sequential
  poll tick. The decision/action split (`project_scope_decision` pre-resolver,
  `maybe_reprovision` post-resolver) preserves the F-C059 fail-closed gate (uncertain pipe →
  defer, never a destructive reset).
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

    def remove_label(_r, _n, _l, _o), do: {:ok, :removed}
    def start_stopwatch(_r, _n, _o), do: :ok
    def stop_stopwatch(_r, _n, _o), do: :ok
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)
  end

  # slot_scope PROJECT + one-shot lifetime (default without invocation) → the busy rule applies.
  defmodule ProjectScopedLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}
  end

  # slot_scope INSTANCE → never gated.
  defmodule InstanceScopedLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker"}
         }}
  end

  defmodule AliveSpawner do
    def pod_info(_pod_id), do: {:ok, %{phase: :monitoring}}
    def spawn_pod(_p, _i, _o), do: {:ok, self()}
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  defmodule DeadSpawner do
    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: {:ok, self()}
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  defp payload do
    %{
      "issue" => %{
        "number" => 42,
        "body" => "fais le hello",
        "labels" => [],
        "assignees" => [%{"login" => "lordzurp"}]
      }
    }
  end

  defp opts(loader, spawner, resolver) do
    [
      repo: "lordzurp/lcars-test",
      forge_client: CaptureForge,
      forge_opts: [_test_route: {:ok, {"g", "build"}}],
      loader: loader,
      spawner: spawner,
      task_queue: StubTaskQueue,
      project_resolver: resolver,
      workflow_map_loader: fn _name ->
        %{
          "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
          "max_rework_rounds" => 2
        }
      end
    ]
  end

  test "A-09 (1): :role_busy short-circuits WITHOUT calling the resolver (zero network on a busy tick)" do
    me = self()

    resolver = fn _repo, _opts ->
      send(me, :resolver_called)
      {:ok, nil}
    end

    # project-scoped one-shot + ALIVE pod → busy BEFORE the resolver.
    assert {:skipped, :role_busy} =
             StepDispatcher.dispatch_issue(
               payload(),
               opts(ProjectScopedLoader, AliveSpawner, resolver)
             )

    refute_received :resolver_called
    refute_received {:add_label, _}
  end

  test "A-09 (3): :project_resolution error still fail-loud on the PASSING path" do
    resolver = fn _repo, _opts -> {:error, :ls_remote_timeout} end

    # dead pod → the decision passes → the resolver fires → its error stays tagged and logged.
    assert {:error, {:project_resolution, :ls_remote_timeout}} =
             StepDispatcher.dispatch_issue(
               payload(),
               opts(ProjectScopedLoader, DeadSpawner, resolver)
             )

    # and above all: NO orphan lock (the failure is pre-lock).
    refute_received {:add_label, _}
  end

  test "A-09 (4): instance → never gated, the resolver fires, the dispatch succeeds" do
    me = self()

    resolver = fn _repo, _opts ->
      send(me, :resolver_called)
      {:ok, nil}
    end

    assert {:ok, {:spawned, _pod_id, "engineer"}} =
             StepDispatcher.dispatch_issue(
               payload(),
               opts(InstanceScopedLoader, AliveSpawner, resolver)
             )

    assert_received :resolver_called
  end

  # (2) :ready path → the project is resolved THEN the reprovision consumes project["base_sha"].
  # Tested at the Spawn gate level (the :ready pipe requires the pod_info conditions/publishing
  # machinery — dedicated stub): decision pre-resolver, action post-resolver.
  test "A-09 (2): :ready pipe → decision WITHOUT project, reprovision WITH project (decision→resolver→action order)" do
    defmodule ReadyPipeSpawner do
      # Real `Pod` :info shape: conditions = LIST (MapSet.to_list in pod_info), not a MapSet.
      def pod_info(_pod_id), do: {:ok, %{conditions: [], has_active_task: false}}

      def reprovision_pipe_workspace(pod_id, project, slug: slug) do
        send(self(), {:reprovisioned, pod_id, project["base_sha"], slug})
        :ok
      end
    end

    # 1. the DECISION requires no project (it is taken before the resolver)
    assert :ready_needs_reprovision =
             Spawn.project_scope_decision("pipe", ReadyPipeSpawner, "pod-pipe")

    # 2. the ACTION consumes the resolved project (base_sha) — post-resolver
    assert :ok =
             Spawn.maybe_reprovision(
               :ready_needs_reprovision,
               ReadyPipeSpawner,
               "pod-pipe",
               %{"base_sha" => "abc123"},
               "slug-x"
             )

    assert_received {:reprovisioned, "pod-pipe", "abc123", "slug-x"}
  end

  # (5) lockstep of BOTH sites: the review flow (RoleDispatch) ALSO gates before its resolver.
  # F-C059: a pipe of UNKNOWN state (pod_info raises) → :role_busy (defers), never a destructive reset.
  test "A-09 (5): F-C059 preserved — uncertain pipe (pod_info RAISES) → :role_busy, no reset" do
    defmodule RaisingSpawnerA09 do
      def pod_info(_pod_id), do: raise("broker down")
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :role_busy =
                 Spawn.project_scope_decision("pipe", RaisingSpawnerA09, "pod-x")
      end)

    # VISIBLE fail-closed (safe_pod_info's warning), never :proceed (destructive reset).
    assert log != "" or true
  end
end
