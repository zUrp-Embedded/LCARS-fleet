defmodule Fleet.Pilot.PodReaperTest do
  @moduledoc """
  A dead ticket takes its pods with it — and touches nothing else.

  The registry is the source of truth (never an enumeration of roles): every live pod whose id
  ENCODES this issue dies, whatever its role. A project-scoped pod encodes no instance, so it is
  structurally out of reach — which is the point: the architect outlives the tickets.
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

    # The REAL seam (`Fleet.Spawner.list_pods/0`) enumerates the pods' `:info` MAPS. This fake
    # used to return bare ids — and that single divergence hid, for the whole life of the module,
    # the fact that the reaper matched nothing at all.
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
    TestEnv.put_env_restoring(:fleet_pilot, :spawner, FleetSpawner)
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
    TestEnv.put_env_restoring(:fleet_pilot, :spawner, AlreadyDeadSpawner)
    assert [] == PodReaper.reap_issue("fleet/myproj", 42)
  end

  test "no pod on this ticket → empty list, nothing killed" do
    assert [] == PodReaper.reap_issue("fleet/myproj", 999)
    refute_received {:killed, _}
  end

  # ─── Le mur : une derive de forme du seam CRIE, elle ne filtre plus ───────────────────────────
  # Le defaut du 2026-08-04 n'etait pas une mauvaise regle, c'etait une regle qui ne voyait rien :
  # `parse_ref/2` garde sur `is_binary`, donc chaque map tombait dans son clause fourre-tout, la
  # comprehension rendait `[]`, et les deux appelants sont best-effort — silence complet. Un module
  # qui TUE des pods ne doit jamais deviner ce qu'il regarde.
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
      TestEnv.put_env_restoring(:fleet_pilot, :spawner, LegacyShapeSpawner)

      assert_raise ArgumentError, ~r/expected a map carrying :pod_id/, fn ->
        PodReaper.reap_issue("fleet/myproj", 42)
      end
    end

    test "une entree de registre sans pod_id est SAUTEE, et elle le dit" do
      TestEnv.put_env_restoring(:fleet_pilot, :spawner, PartialInfoSpawner)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert PodReaper.reap_issue("fleet/myproj", 42) == []
        end)

      assert log =~ "without :pod_id"
    end
  end
end
