defmodule Fleet.Pilot.Poller.LeaseDependsTest do
  @moduledoc """
  A ticket whose declared blocker is still OPEN must not START.

  The forge already enforces the other end — it refuses to CLOSE an issue while a blocker is open.
  Without this read, the fleet dispatches anyway: the producer works, delivers, and the wall only
  shows up at the merge. Two rails that meet at the most expensive moment — the exact state the CI
  was in before its gate.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller.Lease

  defp issue(n), do: %{"number" => n, "title" => "t#{n}", "body" => "b", "labels" => []}

  # The dispatcher records what actually started. The number is read at `payload["issue"]["number"]`
  # — NOT at `payload["number"]`, which does not exist: a fake that reads the wrong key sends `nil`
  # for every ticket and the test passes while measuring nothing (that exact shape was found in a
  # counting dispatcher on 2026-08-03).
  defmodule Dispatcher do
    def dispatch_issue(payload, _opts) do
      send(self(), {:dispatched, get_in(payload, ["issue", "number"])})
      {:ok, :dispatched}
    end
  end

  defmodule Forge do
    # #1 is blocked by #7 (open) ; #2 is blocked by #8 (CLOSED = satisfied) ; #3 has no edge.
    def issue_dependencies(_repo, 1, _opts), do: {:ok, [%{"number" => 7, "state" => "open"}]}
    def issue_dependencies(_repo, 2, _opts), do: {:ok, [%{"number" => 8, "state" => "closed"}]}
    def issue_dependencies(_repo, 3, _opts), do: {:ok, []}
    # #4: the forge cannot answer.
    def issue_dependencies(_repo, 4, _opts), do: {:error, :boom}

    # No engraved route: every ticket here is a FRESH start, which is the only branch the
    # precondition gates (an engaged run is already past it).
    def route_from_labels(_labels), do: :none
  end

  defp seams do
    %Lease.Seams{
      forge: Forge,
      repo: "fleet/demo",
      forge_opts: [],
      workflow_map_loader: nil,
      incident_fun: fn _, _, _, _ -> :ok end,
      dispatcher: Dispatcher
    }
  end

  defp run(issues), do: Lease.process_issues(issues, MapSet.new(), [], seams())

  describe "the precondition gates the START" do
    test "an OPEN blocker holds the ticket back — and it is not dispatched" do
      run([issue(1)])
      refute_received {:dispatched, 1}
    end

    test "a CLOSED blocker is satisfied — the ticket starts" do
      run([issue(2)])
      assert_received {:dispatched, 2}
    end

    test "no edge at all changes nothing — the nominal path stays nominal" do
      run([issue(3)])
      assert_received {:dispatched, 3}
    end

    test "an unreadable forge dispatches: the close-side wall still holds, a network hiccup must not stop the fleet" do
      run([issue(4)])
      assert_received {:dispatched, 4}
    end
  end

  describe "the refusal is NAMED" do
    test "a held ticket carries the `wait/depends` vocabulary, never a silence" do
      assert Fleet.Labels.wait_for({:depends, 7}) == "wait/depends"
    end
  end
end
