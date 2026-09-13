defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle.MergeFailureDispatchTest do
  @moduledoc """
  Checks merge-failure routing through dispatch_review/2 with injected forge and
  conflict engine results. Covers producer/exception/escalation paths and the PR
  face passed to diagnosis; these doubles do not perform a real merge or conflict resolution.
  """
  # Serialized: tests change global conflict flags, implementation modules and credentials settings.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepDispatcher

  import Fleet.Pilot.DispatcherBench

  describe "dispatch_review/2 — merge failure routing and the conflict ladder" do
    # Classify fresh PR fields rather than treating every merge refusal as Git conflict.

    test "merge failure + REAL git conflict, budget available → producer CONFLICT-REWORK (tier 1), no escalation" do
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_route: {:ok, {"g", "build"}},
            _test_merge_result: {:error, {:http, 409, "conflict"}},
            _test_conflict_rounds: {:ok, 0},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => false
            }
          ]
        )

      assert {:ok, _} = StepDispatcher.dispatch_review(pr, opts)

      # Observe a spawn request without merge; role/brief detail is tested elsewhere.
      assert_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "merge failure + REAL conflict, budget EXHAUSTED → honest arch escalation (tier 3)" do
      # Supply chief credentials so the attempted merge can reach the injected conflict failure.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_resolver_role, "chief")
      Fleet.TestEnv.put_role_token!("chief", "CHIEF-TOKEN")

      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 409, "conflict"}},
            _test_route: {:ok, {"g", "build"}},
            # rounds ≥ budget (2, default loader) → no more automatic rework.
            _test_conflict_rounds: {:ok, 2},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => false
            }
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "merge failure + PR mergeable:true (POLICY: human re-request) → re-dispatches the re-requested judge" do
      # A protection refusal with a re-request should summon that judge.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6,
          "head" => %{"ref" => "lcars/issue-42-engineer"}
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "Does not have enough approvals"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: ["qualifier"]
          ]
        )

      assert {:ok, {:spawned, _pod, "qualifier"}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:merged, _}
    end

    test "merge failure + PR mergeable:true WITHOUT re-request → honest escalation (unliftable policy, no silent wedge)" do
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
            _test_rerequested: []
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
    end

    # Inject full diagnostic shapes, including files/hunks and totals, so report rendering
    # as well as routing can consume them.
    defmodule AllSemanticProbe do
      def probe(_repo, _ref, _opts) do
        {:ok,
         %{
           files: %{
             "lib/a.ex" => %{
               hunks: [
                 %Fleet.Conflict.Hunk{
                   base_lines: [],
                   ours_lines: ["a"],
                   theirs_lines: ["b"],
                   start_line: 12,
                   type: :complex,
                   confidence: %Fleet.Conflict.ConfidenceScore{score: 10, label: :low},
                   explanation: "deux intentions distinctes",
                   trace: %Fleet.Conflict.DecisionTrace{
                     selected: :complex,
                     summary: "aucun motif trivial ne s'applique",
                     has_base: false
                   },
                   zdiff3: false
                 }
               ]
             }
           },
           totals: %{none_trivial?: true, total: 1, trivial: 0, complex: 1, writable: 0}
         }}
      end
    end

    defmodule AllWritableProbe do
      def probe(_repo, _ref, _opts) do
        {:ok,
         %{
           files: %{
             "lib/b.ex" => %{
               hunks: [
                 %Fleet.Conflict.Hunk{
                   base_lines: ["x"],
                   ours_lines: ["x", "y"],
                   theirs_lines: ["x"],
                   start_line: 3,
                   type: :one_side_change,
                   confidence: %Fleet.Conflict.ConfidenceScore{score: 90, label: :high},
                   explanation: "un seul cote a bouge",
                   trace: %Fleet.Conflict.DecisionTrace{
                     selected: :one_side_change,
                     summary: "la base prouve que seul `ours` a change",
                     has_base: true
                   },
                   zdiff3: false
                 }
               ]
             }
           },
           totals: %{all_writable?: true, total: 1, trivial: 1, complex: 0, writable: 1}
         }}
      end
    end

    defmodule BlindProbe do
      def probe(_repo, _ref, _opts), do: {:error, :cannot_diagnose}
    end

    defmodule ResolvingApplier do
      def apply(_repo, _ref, _opts), do: {:ok, :auto_resolved}
    end

    defp conflict_pr,
      do:
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6,
          # Dispatch overwrites pr_base_branch from the PR object; configure the fixture there.
          "base" => %{"ref" => "main"}
        })

    defp conflict_opts(extra) do
      dispatch_opts(
        Keyword.merge(
          [
            forge_opts: [
              _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
              _test_merge_result: {:error, {:http, 405, "conflit"}},
              _test_pull: %{
                "number" => 6,
                "state" => "open",
                "draft" => false,
                "mergeable" => false
              }
            ]
          ],
          extra
        )
      )
    end

    # Observe diagnosis options independently from downstream fallback routing.
    defmodule DirCapturingProbe do
      def probe(_repo, _ref, opts) do
        send(self(), {:probe_opts, opts})
        {:error, :captured}
      end
    end

    test "la FACE de la PR decide le worktree ou son conflit est resolu" do
      # An ops PR must resolve in the ops worktree, not silently combine it with the code face.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, DirCapturingProbe)

      name = Fleet.Layout.project_name("lordzurp/lcars-test")

      ops_pr = Map.put(conflict_pr(), "base", %{"ref" => "ops"})
      _ = StepDispatcher.dispatch_review(ops_pr, conflict_opts([]))
      assert_received {:probe_opts, ops_opts}
      assert ops_opts[:dir] == Path.join(Fleet.Layout.ops_root(), name)
      assert ops_opts[:base_branch] == "origin/ops"

      # Include code as a counterexample so routing every PR to ops cannot pass.
      _ = StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
      assert_received {:probe_opts, code_opts}
      assert code_opts[:dir] == Path.join(Fleet.Layout.code_root(), name)
      assert code_opts[:base_branch] == "origin/main"
    end

    test "tier-0 : un conflit TOUT-SEMANTIQUE saute le producteur, et sans chief il atteint l'arch" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      # Arm the exception pass to distinguish unavailable execution from a disabled pass.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_exception_pass?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllSemanticProbe)

      # All-semantic diagnosis skips producer rework; unavailable exception execution reaches architect.
      # The shared success result alone would not distinguish the path taken.
      assert {:skipped, {:merge_blocked_escalated, 6}} =
               StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))

      refute_received {:spawned, _issue, _opts}
    end

    test "A1 : passe chief DESARMEE (flag off) → escalade immediate, AUCUNE tentative de dispatch" do
      # Diagnosis and exception dispatch have independent flags.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_exception_pass?, false)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllSemanticProbe)

      # Capture only suppresses log output; its text is not asserted.
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:skipped, {:merge_blocked_escalated, 6}} =
                 StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
      end)

      # Assert no spawn request. This test does not inspect the escalation's disabled-pass reason.
      refute_received {:spawned, _issue, _opts}
    end

    test "tier-0 : un conflit TOUT-ECRIVABLE est resolu par le runtime, sans pod" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllWritableProbe)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_applier, ResolvingApplier)

      # The injected applier permits exercising wiring without a real conflict worktree.
      assert {:ok, {:auto_resolved, 6}} =
               StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
    end

    test "A0 : sans jeton du rail MERGE, le rail conflit ne fait RIEN — il ne resout pas a moitie" do
      # Missing chief credentials stop the merge attempt before conflict diagnosis can be reached.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, true)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllWritableProbe)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_applier, ResolvingApplier)

      # Use a token directory containing only gatekeeper to force the missing-chief path.
      Fleet.TestEnv.put_env_restoring(
        :lcars_fleet,
        :credentials_role_tokens_dir,
        Fleet.TestEnv.tmp_path("lcars-gk-only")
      )

      Fleet.TestEnv.put_role_token!("gatekeeper", "GK-TOKEN")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :role_token_unavailable} =
                   StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
        end)

      # The error log must identify the missing role.
      assert log =~ "chief"
      assert log =~ "fail-closed"

      # These log refutes are not a direct spy on diagnosis/application calls.
      refute log =~ "auto-resolved"
      refute log =~ "conflict-engine:pr-6"
    end

    # Coverage gap: no discriminating unreadable-probe fallback test here.
    # It needs a fixture where legacy producer dispatch differs from direct escalation.

    test "flag OFF : le diagnoser n'est meme pas consulte (le defaut reste le chemin legacy)" do
      # This rejects auto-resolution with diagnosis disabled; it does not directly observe probe calls.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnosis?, false)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_diagnoser, AllWritableProbe)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_conflict_applier, ResolvingApplier)

      refute match?(
               {:ok, {:auto_resolved, 6}},
               StepDispatcher.dispatch_review(conflict_pr(), conflict_opts([]))
             )
    end
  end
end
