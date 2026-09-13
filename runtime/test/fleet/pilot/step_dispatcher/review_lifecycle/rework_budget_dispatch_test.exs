defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.ReworkBudgetDispatchTest do
  @moduledoc """
  Exercises producer rework, the card's round budget and the separate publish-failure brake
  through dispatch_review. Error cases here inject unreadable counters, not a missing card budget.
  """
  # Serial: DispatcherBench uses shared role-token files; parallel safety is not established here.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher

  import Fleet.Pilot.DispatcherBench

  describe "dispatch_review/2 — the rework budget and the publish brake" do
    test "②.1d: one judge requested changes (the others approve) -> re-spawns the PRODUCER" do
      pr =
        pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :changes_requested},
            _test_route: {:ok, {"poc", "build"}},
            _test_feedback: [
              %{"login" => "reviewer", "body" => "le timing des points/traits est faux"}
            ]
          ]
        )

      # The feature branch identifies the producer; the PR carries the dispatch lock.
      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:brief] =~ "REWORK"

      # Include the refusing review's body and author so the producer has actionable feedback.
      assert spawn_opts[:brief] =~ "le timing des points/traits est faux"
      assert spawn_opts[:brief] =~ "reviewer"

      # The rework brief asks for a response summary on the PR.
      assert spawn_opts[:brief] =~ "summary"
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", attrs}
      assert attrs.role == "engineer"
    end

    test "MA-06: rework UNDER budget (rounds <= max) -> producer re-spawn (no escalation)" do
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_rework_rounds: {:ok, 2},
            _test_route: {:ok, {"poc", "build"}}
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)
    end

    test "frein-publish P2: publish streak > budget -> PUBLISH-BRAKE escalation, no re-spawn (the verdict counter is frozen)" do
      # Failed publication yields no new verdict, so the verdict counter can stay below budget
      # while the separate publish streak exhausts it.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"g", "build"}},
            # Verdicts remain within budget while publication failures exceed it.
            _test_rework_rounds: {:ok, 1},
            _test_publish_fails: {:ok, 3}
          ]
        )

      assert {:skipped, {:publish_brake_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:spawned, _, _}
    end

    test "frein-publish P2: streak AT budget -> rework proceeds (the brake bounds, it does not preempt)" do
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:ok, 1},
            _test_publish_fails: {:ok, 2}
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)
    end

    test "frein-publish P2: unreadable publish counter -> escalation, never a blind loop" do
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:ok, 1},
            _test_publish_fails: {:error, {:http, 500, "boom"}}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:spawned, _, _}
    end

    test "MA-06: N PR rework rounds (rounds > budget) -> ARCH ESCALATION (bounded, no infinite churn)" do
      # Review remediation does not use the workflow rebound brake; the forge counter bounds it.
      # This test observes the skip and absence of spawn, not the awaits-arch label.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            # Readable budget 2 distinguishes exhaustion at 3 from a budget-read error.
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:ok, 3}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:spawned, _, _}
    end

    test "MA-06: unreadable budget (forge {:error}) -> escalation (no blind re-spawn)" do
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            # The route/budget is readable; only the counter fails.
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:error, {:http, 500, "boom"}}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:spawned, _, _}
    end

    test "map-level PR budget HONORED: max_rework_rounds:5 bounces at 4 rounds (the default 2 would escalate)" do
      # A nondefault budget distinguishes card data from a hardcoded limit.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"budget5", "build"}},
            _test_rework_rounds: {:ok, 4}
          ],
          workflow_map_loader: fn "budget5" ->
            %{
              "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
              "max_rework_rounds" => 5
            }
          end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)
    end
  end
end
