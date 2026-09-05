defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.ReworkBudgetDispatchTest do
  @moduledoc """
  The judge rework and its budget, through `dispatch_review/2`: a request for changes re-spawns
  the producer under the card's `max_rework_rounds`, the publish brake bounds without preempting,
  and an unreadable budget escalates rather than looping blind.
  """
  # `async: false`, inherited from the file these witnesses were cut from and not re-audited: the
  # bench itself writes no application env, but role tokens are files under a shared dir
  # (`Fleet.TestEnv.put_role_token!/2`), and this file is not the place to prove the rail is
  # parallel-safe.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher

  import Fleet.Pilot.DispatcherBench

  describe "dispatch_review/2 — the rework budget and the publish brake" do
    test "②.1d: one judge requested changes (the others approve) -> re-spawns the PRODUCER" do
      # all requested judges have a verdict (empty pending), but one :changes_requested → rework.
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

      # producer = git_native role of head (lcars/issue-42-engineer) = engineer; lock on the PR.
      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:brief] =~ "REWORK"

      # Info-starvation fix (rework): the REQUEST_CHANGES review BODY is injected (otherwise
      # "fix according to the review" is hollow → the eng guesses blindly → blocked_dep/wedge,
      # proven live morse).
      assert spawn_opts[:brief] =~ "le timing des points/traits est faux"
      assert spawn_opts[:brief] =~ "reviewer"

      # The eng's voice (rework): the brief asks for a `summary` = answer to the reviewer, posted
      # on the PR.
      assert spawn_opts[:brief] =~ "summary"
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", attrs}
      assert attrs.role == "engineer"
    end

    test "MA-06: rework UNDER budget (rounds <= max) -> producer re-spawn (no escalation)" do
      # Lower-bound guard: as long as the budget is not exhausted, rework continues normally.
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
      # The measured hole: a rework whose PUBLICATION fails produces no verdict → `rounds` freezes
      # under budget → the old brake never fires → a real producer session burned per tick,
      # unbounded (faceproof bench, 5 identical rounds). The publish streak is the counter that
      # moves — over the SAME budget, it must escalate BEFORE any re-spawn.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"g", "build"}},
            # rounds frozen at 1 (under budget 2) — exactly the loop's shape...
            _test_rework_rounds: {:ok, 1},
            # ...while the publish failures accumulated past the budget.
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
      # Illegal state before MA-06: `dispatch_rework` re-spawned the producer with NO counter → if
      # the eng never satisfies the judge, INFINITE rework (the workflow_map `rebound` brake is not
      # called on this path). The fix bounds by a forge-native counter (nb REQUEST_CHANGES):
      # > budget (2) → arch escalation (no re-spawn). We verify the return
      # {:skipped, {:rework_exhausted_escalated, _}} + the awaits-arch label set.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            # Route present → the budget (= max_rework_rounds:2 of the generic loader) is READABLE:
            # we truly test "rounds(3) > budget(2) → escalation", not an unreadable budget
            # (covered by the next test).
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:ok, 3}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      # NO producer re-spawn (end of churn); the human awaits-arch lock is set on the ISSUE.
      refute_received {:spawned, _, _}
    end

    test "MA-06: unreadable budget (forge {:error}) -> escalation (no blind re-spawn)" do
      # Symmetric of `rebound`: an unverifiable budget must NOT loop → we escalate to the arch.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            # Route present → readable budget: we truly test the unreadable COUNTER (count
            # {:error}), not the route.
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:error, {:http, 500, "boom"}}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:spawned, _, _}
    end

    test "map-level PR budget HONORED: max_rework_rounds:5 bounces at 4 rounds (the default 2 would escalate)" do
      # Proof that the PR budget comes from the map's DATA (spec.max_rework_rounds), not a coded
      # default: a map at 5 lets 4 rounds bounce (4 ≤ 5) where the old default of 2 would have
      # escalated.
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
