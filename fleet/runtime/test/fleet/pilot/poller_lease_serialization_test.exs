defmodule Fleet.Pilot.PollerLeaseSerializationTest do
  @moduledoc """
  `max_fan` — how many workflow_runs one PROJECT holds in flight at once.

  It replaces the `:repo_serialized_lease` boolean, and these tests changed with it rather than
  passing unchanged: they used to set a boolean and assert "one or all". The boolean and the
  counter were the same parameter at two resolutions — **serial IS this ceiling at 1** — and the
  `false` side was genuinely unbounded, which is what the ceiling ends.

  async: false — the knob is a global config.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Poller.Admission
  alias Fleet.Pilot.Poller.Lease
  alias Fleet.TestEnv

  defmodule NoRouteForge do
    # No `wfmap/*` route engraved: every issue is a fresh one → QUEUED, never ENGAGED. The lease
    # DERIVES the route from the labels it already holds, so `:none` here is the answer to a
    # question asked without I/O — a stub of `get_route/3` would answer one nobody asks anymore.
    def route_from_labels(_labels), do: :none

    # The refusal now WRITES: a full project says so on the ticket instead of skipping in silence.
    def add_label(_repo, n, label, _opts) do
      send(self(), {:add_label, n, label})
      {:ok, :added}
    end

    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
  end

  defmodule CountingDispatcher do
    # Stands in for StepDispatcher: counts what the lease let through.
    def dispatch_issue(payload, _opts) do
      send(self(), {:dispatched, payload["number"] || payload[:number]})
      {:ok, {:spawned, "pod", "engineer"}}
    end
  end

  defp seams do
    %Lease.Seams{
      forge: NoRouteForge,
      repo: "fleet/p",
      forge_opts: [],
      workflow_map_loader: Fleet.Workflow.Loader,
      incident_fun: fn _, _, _, _ -> :ok end,
      dispatcher: CountingDispatcher
    }
  end

  defp opts, do: [forge_client: NoRouteForge, repo: "fleet/p", forge_opts: []]

  defp issues, do: for(n <- [41, 42, 43], do: %{"number" => n, "labels" => []})

  test "max_fan = 1 IS serialization → ONE run starts, the rest waits" do
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 1)

    tally = Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert tally.dispatched == 1
    assert tally.skipped == 2
  end

  test "a refused ticket carries wait/capacity — the ceiling is not silent" do
    # The lease branch never converged its wait label: a ticket held back was indistinguishable
    # from a forgotten one. It is the same refusal as the ceiling's, so it is the same label.
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 1)

    Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert_received {:add_label, 42, "wait/capacity"}
    assert_received {:add_label, 43, "wait/capacity"}
    refute_received {:add_label, 41, _}
  end

  test "max_fan = 3 → the three queued tickets start in the same tick" do
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 3)

    tally = Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert tally.dispatched == 3
    assert tally.skipped == 0
  end

  test "max_fan = 2 → two start, the third waits (the counter is not a boolean)" do
    # The shape the boolean could not express, and the reason for the item: "one" and "all" were
    # the only two answers it had.
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 2)

    tally = Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert tally.dispatched == 2
    assert tally.skipped == 1
  end

  test "a ticket already in its JURY phase eats a seat" do
    # 5.1's repair, read through the ceiling: in-flight crosses both rails, so a jury ticket fills
    # the project as surely as a producer does.
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 2)

    # #41 carries an open fleet PR → skipped on this rail, but it counts.
    tally = Lease.process_issues(issues(), MapSet.new([41]), opts(), seams())

    assert tally.dispatched == 1
    assert tally.skipped == 2
  end

  describe "max_fan/0 — the reader clamps, it does not report" do
    test "absent → the default 5" do
      TestEnv.restore_env_on_exit(:fleet_pilot, :max_fan)
      Application.delete_env(:fleet_pilot, :max_fan)

      assert Admission.max_fan() == 5
    end

    test "below 1 or above the ceiling → clamped, never zero and never a slot that does not exist" do
      # A ceiling of 0 would be a fleet that dispatches nothing while reporting healthy; above 15 is
      # a producer asking for a pool seat `PoolSlot` does not have. Clamped HERE because this is read
      # on every dispatch decision: a bad value must fail at a DOOR, once, not every thirty seconds.
      TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 0)
      assert Admission.max_fan() == 1

      Application.put_env(:fleet_pilot, :max_fan, 999)
      assert Admission.max_fan() == Admission.max_fan_ceiling()

      Application.put_env(:fleet_pilot, :max_fan, "trois")
      assert Admission.max_fan() == 5
    end
  end
end
