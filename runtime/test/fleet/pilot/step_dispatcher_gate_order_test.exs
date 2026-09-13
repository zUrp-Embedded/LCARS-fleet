defmodule Fleet.Pilot.StepDispatcherGateOrderTest do
  @moduledoc """
  Checks that busy scope admission avoids project resolution and locking.
  Resolution can require slow Git reads; route/card reads may themselves involve I/O.
  Separate helper tests check reset arguments and preservation of ticket context.
  """
  use ExUnit.Case, async: true

  alias Fleet.Forge.PayloadFixture
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

  # Pipe profile uses project scope and requires readiness information before reuse.
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

  # One-shot profile bypasses the scope gate; instance scope alone is not sufficient.
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
      "issue" =>
        PayloadFixture.issue(
          number: 42,
          body: "fais le hello",
          label_names: [],
          assignee_logins: ["lordzurp"]
        )
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

    # Partial pipe information conservatively defers before resolution.
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

  # Compare ready-state decisions for instance and project scope.
  test "TICKET-LIVE: a context-long producer keyed on the ISSUE is re-briefed, never cleared" do
    # Ticket rework must preserve its context; switching a shared pod to another ticket needs reset.
    defmodule TicketLiveSpawner do
      def pod_info(_pod_id), do: {:ok, %{conditions: [], has_active_task: false}}

      def reprovision_pipe_workspace(pod_id, _project, _opts) do
        send(self(), {:MUST_NOT_HAPPEN, pod_id})
        :ok
      end
    end

    # instance-keyed + ready = MY ticket coming back (rework) -> re-brief in place
    assert :proceed =
             Spawn.project_scope_decision(
               "pipe",
               TicketLiveSpawner,
               "repo-issue-5-engineer",
               "instance"
             )

    # project-keyed + ready = free for ANOTHER subject -> the reset stays legitimate there
    assert :ready_needs_reprovision =
             Spawn.project_scope_decision("pipe", TicketLiveSpawner, "repo-engineer", "project")

    # and `:proceed` never reaches the action: nothing is reset, nothing is cleared
    assert :ok =
             Spawn.maybe_reprovision(
               :proceed,
               TicketLiveSpawner,
               "repo-issue-5-engineer",
               %{},
               "work"
             )

    refute_received {:MUST_NOT_HAPPEN, _}
  end

  test "TICKET-LIVE: a busy producer still defers, whatever its keying" do
    defmodule BusyTicketSpawner do
      def pod_info(_pod_id), do: {:ok, %{conditions: [], has_active_task: true}}
    end

    assert :role_busy =
             Spawn.project_scope_decision(
               "pipe",
               BusyTicketSpawner,
               "repo-issue-5-engineer",
               "instance"
             )
  end

  test "A-09 (2): :ready pipe → decision WITHOUT project, reprovision WITH project (decision→resolver→action order)" do
    defmodule ReadyPipeSpawner do
      # Real `Pod` :info shape: conditions = LIST (MapSet.to_list in pod_info), not a MapSet.
      def pod_info(_pod_id), do: {:ok, %{conditions: [], has_active_task: false}}

      def reprovision_pipe_workspace(pod_id, project, slug: slug) do
        send(self(), {:reprovisioned, pod_id, project["base_sha"], slug})
        :ok
      end
    end

    # Explicit project scope requests reprovision; the decision does not need a resolved project.
    assert :ready_needs_reprovision =
             Spawn.project_scope_decision("pipe", ReadyPipeSpawner, "pod-pipe", "project")

    # Supply the resolved pin directly to the action; this test does not invoke a resolver.
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

  # Both flows use this helper; a raised pipe probe must yield a visible deferral.
  test "A-09 (5): F-C059 preserved — uncertain pipe (pod_info RAISES) → :role_busy, no reset" do
    defmodule RaisingSpawnerA09 do
      def pod_info(_pod_id), do: raise("broker down")
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :role_busy =
                 Spawn.project_scope_decision("pipe", RaisingSpawnerA09, "pod-x", "project")
      end)

    # Assert the specific warning, not merely that capture_log returned some text.
    assert log =~ "safe_pod_info"
    assert log =~ "pod_info RAISED"
    assert log =~ "fail-closed"
    assert log =~ "broker down"
  end
end
