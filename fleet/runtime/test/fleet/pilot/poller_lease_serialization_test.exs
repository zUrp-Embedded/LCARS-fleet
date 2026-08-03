defmodule Fleet.Pilot.PollerLeaseSerializationTest do
  @moduledoc """
  The repo-serialized lease becomes DISCONNECTABLE.

  ON (the default, historical): one repo starts at most ONE workflow_run per tick — the second
  QUEUED issue is skipped and waits. It is what made the per-ticket producers and their pool
  slots theoretical: a repo could never hold two producers.

  OFF: every QUEUED issue of the tick starts, and the ceilings that count something take over
  (`max_pods_per_role`, then the global `max_pods`) — those refuse in a typed way, so a ticket
  stacks instead of vanishing.

  async: false — the knob is a global config.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Poller.Lease
  alias Fleet.TestEnv

  defmodule NoRouteForge do
    # No `wfmap/*` route engraved: every issue is a fresh one → QUEUED, never ENGAGED.
    def get_route(_repo, _n, _opts), do: :none
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

  defp issues, do: for(n <- [41, 42, 43], do: %{"number" => n, "labels" => []})

  test "serialization ON (default) → ONE workflow_run started, the rest waits" do
    TestEnv.put_env_restoring(:fleet_pilot, :repo_serialized_lease, true)

    tally = Lease.process_issues(issues(), MapSet.new(), [], seams())

    assert tally.dispatched == 1
    assert tally.skipped == 2
  end

  test "serialization OFF → every queued issue starts in the same tick" do
    TestEnv.put_env_restoring(:fleet_pilot, :repo_serialized_lease, false)

    tally = Lease.process_issues(issues(), MapSet.new(), [], seams())

    assert tally.dispatched == 3
    assert tally.skipped == 0
  end
end
