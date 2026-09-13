defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.CiGateDispatchTest do
  @moduledoc """
  Exercises post-merge-refusal CI rework and waiting through dispatch_review/2.
  CI rework uses an issue marker separate from judge verdict counts. Ignore policy
  does not bypass forge protection; this recovery path still reads actual CI state.
  """
  # Shared fixtures use a global role-token directory; keep access serialized.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher

  import Fleet.Pilot.DispatcherBench

  alias Fleet.Pilot.DispatcherBench.StubSpawnerAlive

  describe "dispatch_review/2 — the CI gate on the PR rail" do
    test "merge blocked by a RED CI → PRODUCER rework, not a human (the rung, 2026-08-03)" do
      # A forge policy refusal with failed CI must reach producer rework instead of unexplained escalation.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure
          ]
        )

      # Assert an actual spawn request; rejecting only one escalation shape would miss the other.
      assert {:ok, _} = StepDispatcher.dispatch_review(pr, opts)
      assert_received {:spawned, _issue, _opts}
    end

    test "CI rouge : le round est COMPTE sur le ticket — sinon le budget ne borne rien" do
      # CI creates no changes-requested reviews, so it needs its own issue marker count.
      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            # Supply a SHA so the marker describes the measured head, not a branch-ref fallback.
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"}
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure,
            _test_ci_reworks: {:ok, 0}
          ]
        )

      assert {:ok, _} =
               StepDispatcher.dispatch_review(
                 pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
                 opts
               )

      assert_received {:spawned, _issue, _opts}
      assert_received {:ci_rework_marked, 42}
    end

    test "CI rouge mais le producteur est OCCUPE : rien n'est lance, donc RIEN n'est facture" do
      # This post-merge path must not charge a rework marker for busy admission.
      # It is distinct from the pre-jury PR marker written before dispatch.
      opts =
        dispatch_opts(
          spawner: StubSpawnerAlive,
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"}
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure,
            _test_ci_reworks: {:ok, 0}
          ]
        )

      StepDispatcher.dispatch_review(
        pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
        opts
      )

      refute_received {:spawned, _issue, _opts}
      refute_received {:ci_rework_marked, 42}
    end

    test "A-09 (1) on the REVIEW rail: :role_busy short-circuits WITHOUT calling the resolver" do
      # Busy scope must avoid project resolution; this does not prove absence of all network reads.
      me = self()

      opts =
        dispatch_opts(
          spawner: StubSpawnerAlive,
          project_resolver: fn _repo, _opts ->
            send(me, :resolver_called)
            {:ok, nil}
          end,
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"g", "build"}}
          ]
        )

      assert {:skipped, :role_busy} =
               StepDispatcher.dispatch_review(
                 pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
                 opts
               )

      refute_received :resolver_called
      refute_received {:spawned, _, _}
    end

    test "CI rouge AU-DELA du budget : l'architecte est saisi, et aucun pod de plus" do
      # `max_rework_rounds` vaut 2 dans ces fixtures : deux rounds deja depenses ferment la porte.
      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            # Keep the marker keyed to a SHA rather than the branch-ref fallback.
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"}
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure,
            _test_ci_reworks: {:ok, 2}
          ]
        )

      StepDispatcher.dispatch_review(
        pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
        opts
      )

      refute_received {:spawned, _issue, _opts}
      # Check no spawn/marker; the returned escalation itself is not asserted by this test.
      refute_received {:ci_rework_marked, 42}
    end

    test "CI rouge, compteur ILLISIBLE : on escalade, on ne boucle pas en aveugle" do
      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            # Keep the marker keyed to a SHA rather than the branch-ref fallback.
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"}
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :failure,
            _test_ci_reworks: {:error, :forge_down}
          ]
        )

      StepDispatcher.dispatch_review(
        pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
        opts
      )

      refute_received {:spawned, _issue, _opts}
    end

    test "merge blocked while the CI is still PENDING → the next tick asks again, nobody is summoned" do
      # Pending is not failed CI. This fixture lacks a date, so its wait can remain unbounded.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: [],
            _test_ci: :pending
          ]
        )

      assert {:skipped, :ci_pending} = StepDispatcher.dispatch_review(pr, opts)
    end

    test "CI PENDANTE au-dela de la borne : l'attente s'arrete et le DIT — sinon elle est infinie" do
      # Even an ignore card cannot bypass a pending CI check imposed by forge protection.
      vieux =
        DateTime.utc_now()
        # Independent fixture age must not derive from the production threshold.
        |> DateTime.add(-(45 * 60 + 60), :second)
        |> DateTime.to_iso8601()

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"},
              "updated_at" => vieux
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :pending
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} =
               StepDispatcher.dispatch_review(
                 pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
                 opts
               )

      refute_received {:spawned, _issue, _opts}
    end

    test "CI PENDANTE dont la DATE est illisible : on attend, on n'escalade pas sur ce qu'on n'a pas lu" do
      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true,
              "head" => %{"sha" => "abcdef0123456789abcdef0123456789abcdef01"},
              "updated_at" => "pas une date"
            },
            _test_rerequested: [],
            _test_route: {:ok, {"g", "build"}},
            _test_ci: :pending
          ]
        )

      assert {:skipped, :ci_pending} =
               StepDispatcher.dispatch_review(
                 pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6}),
                 opts
               )
    end

    test "…mais une carte `ci: ignore` ne doit PAS attendre la CI, meme sur ce chemin" do
      # On this recovery path, none differs from pending; ignore does not repeal forge protection.
      # This assertion rejects only ci_pending and does not prove successful progress.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          workflow_map_loader: fn _name ->
            %{
              "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
              "max_rework_rounds" => 2,
              "ci" => "ignore"
            }
          end,
          forge_opts: [
            _test_route: {:ok, {"g", "build"}},
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: [],
            _test_ci: :none
          ]
        )

      refute match?({:skipped, :ci_pending}, StepDispatcher.dispatch_review(pr, opts)),
             "sans runner (:none), une carte `ci: ignore` ne doit jamais produire wait/ci"
    end

    test "A0.5 : un merge bloque par des status checks EN COURS retick — jamais une escalade arch" do
      # Pending status after a protection refusal waits, even when the card ignores jury CI.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result:
              {:error, {:http, 405, "Not all required status checks successful"}},
            _test_route: {:ok, {"g", "build"}},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => true
            },
            _test_ci: :pending
          ]
        )

      assert {:skipped, :ci_pending} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:spawned, _, _}
    end
  end
end
