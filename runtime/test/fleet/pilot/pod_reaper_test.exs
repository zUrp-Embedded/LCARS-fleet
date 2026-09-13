defmodule Fleet.Pilot.PodReaperTest do
  @moduledoc """
  Checks issue/PR/project identity separation, profile guards and enumeration shape.
  Serialized because the injected :pilot_spawner is global application state.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.PodReaper
  alias Fleet.TestEnv

  defmodule FleetSpawner do
    @pods [
      # the two ticket-scoped pods of issue 42 — both must die
      "fleet-myproj-issue-42-engineer",
      "fleet-myproj-issue-42-qualifier",
      # another ticket of the SAME repo — untouched
      "fleet-myproj-issue-43-engineer",
      # a PR-keyed judge of the same number — different phase, untouched
      "fleet-myproj-pr-42-reviewer",
      # the project-scoped architect — encodes no instance, structurally unreachable
      "fleet-myproj-architect",
      # the same issue number in ANOTHER repo — the repo scope is what disambiguates
      "fleet-other-issue-42-engineer"
    ]

    # Match the real list_pods contract: info maps, not bare IDs. A bare-ID fake
    # would hide a reaper that silently fails to extract production IDs.
    def list_pods, do: Enum.map(@pods, &%{pod_id: &1, role: "engineer", phase: :running})

    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end
  end

  defmodule AlreadyDeadSpawner do
    def list_pods, do: [%{pod_id: "fleet-myproj-issue-42-engineer", role: "engineer"}]

    def kill_pod(_pod_id), do: {:error, :not_found}
  end

  setup do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, FleetSpawner)
    :ok
  end

  test "reaps EVERY pod of the ticket, and only those" do
    reaped = PodReaper.reap_issue("fleet/myproj", 42)

    assert Enum.sort(reaped) == [
             "fleet-myproj-issue-42-engineer",
             "fleet-myproj-issue-42-qualifier"
           ]

    refute_received {:killed, "fleet-myproj-issue-43-engineer"}
    refute_received {:killed, "fleet-myproj-pr-42-reviewer"}
    refute_received {:killed, "fleet-myproj-architect"}
    refute_received {:killed, "fleet-other-issue-42-engineer"}
  end

  test "a pod already dead is not reported as reaped (idempotent on replay)" do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, AlreadyDeadSpawner)
    assert [] == PodReaper.reap_issue("fleet/myproj", 42)
  end

  test "no pod on this ticket → empty list, nothing killed" do
    assert [] == PodReaper.reap_issue("fleet/myproj", 999)
    refute_received {:killed, _}
  end

  # Reject an incompatible enumeration shape rather than silently reaping nothing.
  defmodule LegacyShapeSpawner do
    def list_pods, do: ["fleet-myproj-issue-42-engineer"]
    def kill_pod(_), do: :ok
  end

  defmodule PartialInfoSpawner do
    # A registry entry that answers `:info` without a `pod_id` (a pool holder, in the suite): we
    # cannot bind it to a ticket, so we skip it — but out loud.
    def list_pods, do: [%{phase: :monitoring}]
    def kill_pod(_), do: :ok
  end

  describe "le seam d'enumeration" do
    test "une forme inattendue (ids nus, la forme d'avant) leve, au lieu de moissonner zero pod" do
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, LegacyShapeSpawner)

      assert_raise ArgumentError, ~r/expected a map carrying :pod_id/, fn ->
        PodReaper.reap_issue("fleet/myproj", 42)
      end
    end

    test "une entree de registre sans pod_id est SAUTEE, et elle le dit" do
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, PartialInfoSpawner)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert PodReaper.reap_issue("fleet/myproj", 42) == []
        end)

      assert log =~ "without :pod_id"
    end
  end

  describe "reap_producer/3 — the sealed producer, one precise id, ticket-scoped only" do
    test "engineer (slot_scope: instance) → its ticket pod dies, keyed on the ISSUE" do
      assert :ok = PodReaper.reap_producer("fleet/myproj", 42, "engineer")
      assert_received {:killed, "fleet-myproj-issue-42-engineer"}
      refute_received {:killed, _}
    end

    test "architect (slot_scope: project) → never touched: it outlives the ticket by design" do
      assert :ok = PodReaper.reap_producer("fleet/myproj", 42, "architect")
      refute_received {:killed, _}
    end

    test "an empty producer name reaps nothing, and says :ok" do
      assert :ok = PodReaper.reap_producer("fleet/myproj", 42, "")
      refute_received {:killed, _}
    end
  end

  describe "reap_judge/3 — the ingested judge, keyed on the PR, judges only" do
    test "reviewer (judge, instance) → its PR pod dies once its verdict is ingested" do
      assert :ok = PodReaper.reap_judge("fleet/myproj", 42, "reviewer")
      assert_received {:killed, "fleet-myproj-pr-42-reviewer"}
      refute_received {:killed, _}
    end

    test "a WORKER role is not a judge: nothing dies under a name the seal owns" do
      assert :ok = PodReaper.reap_judge("fleet/myproj", 42, "engineer")
      refute_received {:killed, _}
    end

    test "an already-dead judge is the nominal case: :ok, no error path" do
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, AlreadyDeadSpawner)
      assert :ok = PodReaper.reap_judge("fleet/myproj", 42, "reviewer")
    end
  end
end
