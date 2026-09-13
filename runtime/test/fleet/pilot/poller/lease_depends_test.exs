defmodule Fleet.Pilot.Poller.LeaseDependsTest do
  @moduledoc """
  Checks dependency admission before new work starts, avoiding a blocker discovered
  only when attempting to close the delivered ticket. Uses stub dispatch and reads;
  wait tests check vocabulary, not a forge-label write.
  """
  use ExUnit.Case, async: true

  alias Fleet.Forge.PayloadFixture
  alias Fleet.Pilot.Poller.Lease

  defp issue(n), do: %{"number" => n, "title" => "t#{n}", "body" => "b", "labels" => []}

  # Read the nested issue number; top-level number is absent from dispatch payloads.
  defmodule Dispatcher do
    def dispatch_issue(payload, _opts) do
      send(self(), {:dispatched, get_in(payload, ["issue", "number"])})
      {:ok, :dispatched}
    end
  end

  defmodule Forge do
    # #1 is blocked by #7 (open) ; #2 is blocked by #8 (CLOSED = satisfied) ; #3 has no edge.
    def issue_dependencies(_repo, 1, _opts),
      do: {:ok, [PayloadFixture.issue(number: 7, state: "open")]}

    def issue_dependencies(_repo, 2, _opts),
      do: {:ok, [PayloadFixture.issue(number: 8, state: "closed")]}

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

    # A failed dependency read must defer the ticket. The paired case confirms
    # another ticket can still start rather than stopping the whole pass.
    test "JG-058 : une forge illisible NE dispatche PAS — illisible n'est pas « aucun bloqueur »" do
      run([issue(4)])

      refute_received {:dispatched, 4},
                      "un ticket a ete depeche sur une lecture d'aretes ratee : le producteur part " <>
                        "sur une brique dont la precondition n'est peut-etre pas livree"
    end

    test "JG-058 : et la fleet n'est PAS arretee — les autres tickets partent au meme tick" do
      run([issue(4), issue(3)])

      refute_received {:dispatched, 4}
      assert_received {:dispatched, 3}, "un hoquet sur UN ticket a arrete les autres"
    end
  end

  describe "the refusal is NAMED" do
    test "a held ticket carries the `wait/depends` vocabulary, never a silence" do
      assert Fleet.Labels.wait_for({:depends, 7}) == "wait/depends"
    end

    # Closed and unreadable gates share wait/depends; the skip reason distinguishes them.
    test "JG-058 : une lecture ratee porte la meme etiquette de porte, pas une taxonomie de plus" do
      assert Fleet.Labels.wait_for({:depends_unreadable, :timeout}) == "wait/depends"
    end
  end
end
