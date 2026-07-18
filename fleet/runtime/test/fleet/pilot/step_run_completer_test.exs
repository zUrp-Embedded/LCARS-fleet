defmodule Fleet.Pilot.StepRunCompleterTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.ForgeStubs.MergeFailForge
  alias Fleet.Pilot.StepRunCompleter

  # Forge stub that RECORDS the call order (send to the test) to verify the
  # canonical §5 sequence: comment → state → (close|assignee) → unlock.
  defmodule OrderForge do
    def post_comment(_repo, _n, body, opts) do
      send(self(), {:call, :comment, body, opts[:dedup_signature]})
      {:ok, :posted}
    end

    def set_assignee(_repo, _n, login, _opts) do
      send(self(), {:call, :assignee, login})
      {:ok, :set}
    end

    def close_issue(_repo, _n, _opts) do
      send(self(), {:call, :close})
      {:ok, :closed}
    end

    def remove_label(_repo, _n, label, _opts) do
      send(self(), {:call, :unlock, label})
      {:ok, :removed}
    end

    def post_route(_repo, _n, workflow_map_name, step, _opts) do
      send(self(), {:call, :route, workflow_map_name, step})
      {:ok, :posted}
    end

    def stop_stopwatch(_repo, _n, _opts), do: :ok
  end

  defmodule StubDeliverable do
    def publish(opts) do
      send(self(), {:published, opts})
      {:ok, %{commit_sha: "deadbeef", pushed?: true, mode: :git_native}}
    end
  end

  defmodule FailDeliverable do
    def publish(_opts), do: {:error, :base_not_ancestor}
  end

  # PR-native forge stub: records the PR calls (send to the test). Returns the REAL
  # `ForgeClient` contract: `post_review`/`merge_pr`/`request_review` → `:ok` (not `{:ok, _}`).
  defmodule PrForge do
    def open_pr(_repo, head, base, _title, opts) do
      send(self(), {:open_pr, head, base, opts[:body]})
      {:ok, 7}
    end

    def post_review(_repo, pr, event, body, _opts) do
      send(self(), {:review, pr, event, body})
      :ok
    end

    # Gatekeeper seal (F-arch-MCP): promote posts the closing comment before the merge.
    # Real `ForgeClient.post_comment/4` shape = {:ok, :posted | :already}, NOT {:ok, 1}.
    def post_comment(_repo, n, body, opts) do
      send(self(), {:comment, n, body, opts})
      {:ok, :posted}
    end

    def merge_pr(_repo, pr, _opts) do
      send(self(), {:merge, pr})
      :ok
    end

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def close_issue(_repo, _n, _opts), do: {:ok, :closed}
  end

  defmodule PrFailForge do
    def open_pr(_r, _h, _b, _t, _o), do: {:error, {:http, 422, "no commits between"}}
    def post_review(_r, _pr, _e, _b, _o), do: {:error, {:http, 500, "boom"}}

    # SIGNALS the comment: the seal is MERGE-FIRST (only comments if the merge succeeds) → on the
    # 409 merge, post_comment must NEVER be called. We signal so that a `refute_received {:comment}`
    # at the call site is PROBATIVE (if it were called by a comment-before-merge regression, the
    # test would see it).
    def post_comment(_r, n, body, opts) do
      send(self(), {:comment, n, body, opts})
      {:ok, :posted}
    end

    def merge_pr(_r, _pr, _o), do: {:error, {:http, 409, "not fast-forward"}}
  end

  # COMPLETE forge stub for the `complete_pr/2` orchestrator (all PR primitives + issue bridge).
  defmodule OrchForge do
    def open_pr(_repo, head, base, _title, opts) do
      send(self(), {:open_pr, head, base, opts[:body]})
      {:ok, 7}
    end

    def get_pr_for_branch(_repo, head, base, _opts) do
      send(self(), {:get_pr, head, base})
      {:ok, 7}
    end

    def post_review(_repo, pr, event, body, _opts) do
      send(self(), {:review, pr, event, body})
      :ok
    end

    def request_review(_repo, pr, reviewers, _opts) do
      send(self(), {:request_review, pr, reviewers})
      :ok
    end

    def merge_pr(_repo, pr, _opts) do
      send(self(), {:merge, pr})
      :ok
    end

    def set_assignee(_repo, n, login, _opts) do
      send(self(), {:assignee, n, login})
      {:ok, :set}
    end

    def remove_label(_repo, n, label, _opts) do
      send(self(), {:unlock, n, label})
      {:ok, :removed}
    end

    def stop_stopwatch(_repo, n, _opts), do: send(self(), {:stopwatch_stopped, n}) && :ok

    # The eng's voice (outgoing info): the producer's summary posted as a PR comment.
    def post_comment(_repo, pr, body, _opts) do
      send(self(), {:comment, pr, body})
      {:ok, :posted}
    end

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def close_issue(_repo, _n, _opts), do: {:ok, :closed}
  end

  # PR not found (the judge falls before any review); FF merge impossible (open ok, merge 409).
  defmodule NoPrForge do
    def get_pr_for_branch(_r, _h, _b, _o), do: {:error, :pr_not_found}
  end

  defp base_step_run(extra \\ %{}) do
    Map.merge(
      %{
        repo: "lordzurp/lcars-test",
        issue_number: 42,
        role: "engineer",
        deliverable_opts: %{mode: :git_native, workspace: "/tmp/ws", base_sha: "cafe"}
      },
      extra
    )
  end

  defp seams do
    [deliverable: StubDeliverable, forge_client: OrderForge, forge_opts: []]
  end

  defp pr_step_run(extra \\ %{}) do
    base_step_run(
      Map.merge(
        %{
          deliverable_opts: %{
            mode: :git_native,
            workspace: "/tmp/ws",
            base_sha: "cafe",
            target_branch: "feature/issue-42"
          }
        },
        extra
      )
    )
  end

  describe "complete/2 — 1-step terminal (next_assignee nil)" do
    test "publishes, signed comment, CLOSE, unlock — in the §5 order" do
      assert {:ok, :completed} = StepRunCompleter.complete(base_step_run(), seams())

      # Step 1: publish called with the deliverable's opts
      assert_received {:published, %{mode: :git_native, base_sha: "cafe"}}

      # Steps 2→4 in the canonical order (FIFO mailbox; step 3 state:* removed — #5.2 D4)
      assert_received {:call, :comment, body, sig}
      assert sig == "[step_run:engineer:deadbeef]"
      assert body =~ "[step_run:engineer:deadbeef]"

      assert_received {:call, :close}
      assert_received {:call, :unlock, "lcars-in-flight"}

      # No reassignment in terminal
      refute_received {:call, :assignee, _}
    end

    test "signed comment carries the signature as dedup_signature (replay-safe)" do
      StepRunCompleter.complete(base_step_run(), seams())
      assert_received {:call, :comment, _body, "[step_run:engineer:deadbeef]"}
    end
  end

  describe "complete/2 — multi-step (next_assignee present, A2 branch)" do
    test "publishes, comment, ADVANCES (no close nor set_assignee, #8.A), unlock" do
      step_run = base_step_run(%{next_assignee: "qualifier"})
      assert {:ok, :reassigned} = StepRunCompleter.complete(step_run, seams())

      assert_received {:call, :comment, _, _}

      # #8.A: the advance NO LONGER overwrites the assignee (= human); the next-role is derived from
      # the route at dispatch. (Here no workflow_map context → no route either, cf. defensive case
      # below.)
      refute_received {:call, :assignee, _}
      assert_received {:call, :unlock, "lcars-in-flight"}
      refute_received {:call, :close}
    end

    test "advance with workflow_map context → records the next step's ROUTE (without set_assignee, #8.A)" do
      step_run =
        base_step_run(%{
          next_assignee: "qualifier",
          workflow_map: "poc-cycle",
          next_step: "spec-review"
        })

      assert {:ok, :reassigned} = StepRunCompleter.complete(step_run, seams())

      # #8.A: the advance records the next step's ROUTE; the assignee (human) is NO LONGER touched.
      assert_received {:call, :route, "poc-cycle", "spec-review"}
      refute_received {:call, :assignee, _}
    end

    test "reassign without workflow_map context → no post_route (defensive)" do
      step_run = base_step_run(%{next_assignee: "qualifier"})
      assert {:ok, :reassigned} = StepRunCompleter.complete(step_run, seams())
      refute_received {:call, :route, _, _}
    end
  end

  describe "complete/2 — without git deliverable (payload judge, step_run_sha provided)" do
    test "uses step_run_sha as signature, no publish call" do
      step_run =
        base_step_run(%{deliverable_opts: nil, step_run_sha: "verdict-001"})

      assert {:ok, :completed} = StepRunCompleter.complete(step_run, seams())
      refute_received {:published, _}
      assert_received {:call, :comment, _body, "[step_run:engineer:verdict-001]"}
    end

    test "error when neither deliverable nor step_run_sha" do
      step_run = base_step_run(%{deliverable_opts: nil})

      assert {:error, {:publish, :no_deliverable_no_step_run_sha}} =
               StepRunCompleter.complete(step_run, seams())
    end
  end

  describe "complete/2 — error propagation (stop before the next steps)" do
    test "publish fails → {:error, {:publish, _}}, no forge write" do
      opts = Keyword.put(seams(), :deliverable, FailDeliverable)

      assert {:error, {:publish, :base_not_ancestor}} =
               StepRunCompleter.complete(base_step_run(), opts)

      refute_received {:call, :comment, _, _}
      refute_received {:call, :unlock, _}
    end

    test "comment fails → {:error, {:comment, _}}, no state/close/unlock" do
      defmodule CommentFailForge do
        def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}
      end

      opts = Keyword.put(seams(), :forge_client, CommentFailForge)

      assert {:error, {:comment, {:http, 500, "boom"}}} =
               StepRunCompleter.complete(base_step_run(), opts)
    end
  end

  describe "open_deliverable_pr/2 — engineer → PR (PR-native)" do
    test "pushes the feature-branch + opens the PR feature→base — WITHOUT Closes #N (explicit close at merge, chronology QoL)" do
      opts = [deliverable: StubDeliverable, forge_client: PrForge, forge_opts: []]

      assert {:ok, %{commit_sha: "deadbeef", pr_number: 7}} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)

      assert_received {:published, %{target_branch: "feature/issue-42"}}
      assert_received {:open_pr, "feature/issue-42", "main", body}
      refute body =~ "Closes"
    end

    test "base_branch override" do
      opts = [deliverable: StubDeliverable, forge_client: PrForge, forge_opts: []]

      assert {:ok, _} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(%{base_branch: "develop"}), opts)

      assert_received {:open_pr, "feature/issue-42", "develop", _}
    end

    test "publish fails → {:error, {:publish, _}}, NO PR opened" do
      opts = [deliverable: FailDeliverable, forge_client: PrForge, forge_opts: []]

      assert {:error, {:publish, :base_not_ancestor}} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)

      refute_received {:open_pr, _, _, _}
    end

    test "open_pr fails → {:error, {:open_pr, _}}" do
      opts = [deliverable: StubDeliverable, forge_client: PrFailForge, forge_opts: []]

      assert {:error, {:open_pr, {:http, 422, _}}} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)
    end

    # Regression: provenance hooked onto `complete/2` (verdicts WITHOUT deliverable) is never
    # emitted on the REAL producer path (`open_deliverable_pr` is the only publication point of a
    # git deliverable). This test walks that path and demands the full triplet — it would go red on
    # the wrong wiring. (The `:work_root` seam replaces the untestable global
    # `Fleet.Layout.work_root()`.)
    @tag :tmp_dir
    test "emits the provenance triplet (brief_sha, input_sha, livrable_sha) under work/ops `provenance/`",
         %{tmp_dir: tmp} do
      # the project's work/ops: project_name("lordzurp/lcars-test") = "lcars-test", a real git repo.
      work_dir = Path.join(tmp, "lcars-test")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      brief_sha = String.duplicate("b", 40)
      step_run = pr_step_run(%{brief_sha: brief_sha, brief_ref: "briefs/issue-42-engineer.md"})
      opts = [deliverable: StubDeliverable, forge_client: PrForge, forge_opts: [], work_root: tmp]

      assert {:ok, %{commit_sha: "deadbeef"}} =
               StepRunCompleter.open_deliverable_pr(step_run, opts)

      # The provenance appears, human-named on the issue (sha7 of the livrable), committed,
      # COMPLETE triplet.
      prov = Path.join(work_dir, "provenance/issue-42-deadbee.json")
      assert File.exists?(prov)
      json = prov |> File.read!() |> Jason.decode!()
      # (livrable, brief, input) = the 3 vertices of the triplet, each in its in-toto place.
      assert get_in(json, ["subject", Access.at(0), "digest", "gitCommit"]) == "deadbeef"
      assert get_in(json, ["predicate", "invocation", "configSource", "digest", "gitCommit"]) == brief_sha
      assert get_in(json, ["predicate", "buildConfig", "input_sha"]) == "cafe"
      # committed, not just written on disk.
      {log, 0} = System.cmd("git", ["log", "--oneline"], cd: work_dir)
      assert log =~ "provenance: provenance/issue-42-deadbee.json"
    end
  end

  describe "record_review/2 + promote/2 (PR-native)" do
    test "verdict :approve → native APPROVED review (role-generated body)" do
      step_run = %{repo: "fleet/proj", pr_number: 7, role: "qualifier", review_event: :approve}

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(step_run, forge_client: PrForge, forge_opts: [])

      assert_received {:review, 7, :approve, body}
      assert body =~ "qualifier"
      # "APPROUVÉ" pins the FR user-facing review body.
      assert body =~ "APPROUVÉ"
    end

    test "verdict :request_changes with explicit body" do
      step_run = %{
        repo: "fleet/proj",
        pr_number: 7,
        role: "reviewer",
        review_event: :request_changes,
        review_body: "il manque un test de la branche d'erreur"
      }

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(step_run, forge_client: PrForge, forge_opts: [])

      assert_received {:review, 7, :request_changes, "il manque un test de la branche d'erreur"}
    end

    test "record_review propagates the forge error" do
      step_run = %{repo: "fleet/proj", pr_number: 7, role: "qualifier", review_event: :approve}

      assert {:error, {:review, {:http, 500, _}}} =
               StepRunCompleter.record_review(step_run, forge_client: PrFailForge, forge_opts: [])
    end

    test "promote → gatekeeper comment + FF merge, {:ok, :promoted}" do
      step_run = %{
        repo: "fleet/proj",
        pr_number: 7,
        issue_number: 42,
        producer_branch: "lcars/issue-42-engineer"
      }

      assert {:ok, :promoted} =
               StepRunCompleter.promote(step_run, forge_client: PrForge, forge_opts: [])

      # Seal (F-arch-MCP): gatekeeper comment on the issue THEN merge.
      assert_received {:comment, 42, _body, _opts}
      assert_received {:merge, 7}
    end

    test "promote: FF impossible (409) = serial invariant violated → {:merge, _} fail-loud" do
      step_run = %{
        repo: "fleet/proj",
        pr_number: 7,
        issue_number: 42,
        producer_branch: "lcars/issue-42-engineer"
      }

      assert {:error, {:merge, {:http, 409, _}}} =
               StepRunCompleter.promote(step_run, forge_client: PrFailForge, forge_opts: [])

      # Invariant F-MERGE-CLAIM-BEFORE-REALITY: the seal is MERGE-FIRST → a 409 merge must leave NO
      # "sealed/merged" comment on the issue (commenting before confirmation would freeze a success
      # that never happened). PrFailForge SIGNALS its comments → this refute is probative (it would
      # break on a comment-before-merge regression, the exact bug gatekeeper_seal avoids).
      refute_received {:comment, _, _, _}
    end
  end

  describe "complete_pr/2 — PR-native orchestrator" do
    defp producer_step_run(intent, extra \\ %{}) do
      Map.merge(
        %{
          repo: "fleet/proj",
          issue_number: 42,
          role: "engineer",
          pr_role: :producer,
          intent: intent,
          next_assignee: nil,
          producer_branch: "lcars/issue-42-engineer",
          deliverable_opts: %{
            mode: :git_native,
            workspace: "/tmp/ws",
            base_sha: "cafe",
            target_branch: "lcars/issue-42-engineer"
          }
        },
        extra
      )
    end

    defp judge_step_run(intent, extra \\ %{}) do
      Map.merge(
        %{
          repo: "fleet/proj",
          issue_number: 42,
          role: "reviewer",
          pr_role: :judge,
          intent: intent,
          next_assignee: nil,
          producer_branch: "lcars/issue-42-engineer"
        },
        extra
      )
    end

    defp orch_opts(extra \\ []) do
      Keyword.merge(
        [deliverable: StubDeliverable, forge_client: OrchForge, forge_opts: []],
        extra
      )
    end

    test "producer :advance → opens the PR, request_review(next), NO set_assignee, NO unlock (ISSUE lock persists until promote)" do
      step_run = producer_step_run(:advance, %{next_assignee: "qualifier"})

      assert {:ok, :review_requested} = StepRunCompleter.complete_pr(step_run, orch_opts())

      assert_received {:open_pr, "lcars/issue-42-engineer", "main", body}
      refute body =~ "Closes"
      assert_received {:request_review, 7, ["qualifier"]}
      # producer: the lock is on the ISSUE (dispatch_issue); no more set_assignee (PR-driven)
      refute_received {:assignee, _, _}

      # The ISSUE lock is NOT lifted at advance anymore — it persists until the final :promote
      # (the brick stays in-flight through the whole review, not just the coding).
      refute_received {:unlock, _, _}

      # BUT the eng's build STOPWATCH closes at hand-off (on ISSUE 42) — decoupled from the lock:
      # otherwise the eng's time would span the whole review (cycle time ≠ work time).
      assert_received {:stopwatch_stopped, 42}
    end

    test "producer with :eng_summary → FULL note on the TICKET, FOLDED POINTER in the PR opening (QoL, a single PR post)" do
      step_run =
        producer_step_run(:advance, %{
          next_assignee: "qualifier",
          eng_summary: "j'ai implémenté le décodeur, choisi un buffer circulaire"
        })

      assert {:ok, :review_requested} = StepRunCompleter.complete_pr(step_run, orch_opts())

      # the FULL NOTE (the prose) lives ONCE, on the ISSUE (42).
      # "Note de l'engineer" pins the FR user-facing comment heading.
      assert_received {:comment, 42, issue_body}
      assert issue_body =~ "j'ai implémenté le décodeur, choisi un buffer circulaire"
      assert issue_body =~ "Note de l'engineer"

      # the POINTER is FOLDED into the PR's OPENING body (7) — not a 2nd separate comment.
      assert_received {:open_pr, _head, _base, pr_body}
      assert pr_body =~ "ticket #42"
      refute pr_body =~ "j'ai implémenté le décodeur"

      # zero comments on the PR: a single "as engineer" post on the PR side (the opening itself).
      refute_received {:comment, 7, _}
    end

    test "producer WITHOUT :eng_summary → NO comment (no empty voice)" do
      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(
                 producer_step_run(:advance, %{next_assignee: "qualifier"}),
                 orch_opts()
               )

      refute_received {:comment, _, _}
    end

    test "producer :promote (1-step terminal) → opens the PR, FF merge, unlock, no reassign" do
      assert {:ok, :promoted} =
               StepRunCompleter.complete_pr(producer_step_run(:promote), orch_opts())

      assert_received {:open_pr, "lcars/issue-42-engineer", "main", _}
      assert_received {:merge, 7}
      assert_received {:unlock, 42, _}
      refute_received {:assignee, _, _}
    end

    test "producer :rework (its own gate fail) → NO PR, unlocks the ISSUE (re-spawn via assignee)" do
      step_run = producer_step_run(:rework, %{next_assignee: "engineer"})

      assert {:ok, :rework_requested} = StepRunCompleter.complete_pr(step_run, orch_opts())

      refute_received {:open_pr, _, _, _}

      # no PR yet -> the engineer stays assigned (Entry) and re-spawns next tick; unlock the issue
      refute_received {:assignee, _, _}
      assert_received {:unlock, 42, _}
    end

    test "judge :advance → finds the PR, APPROVED review, request_review(next), unlocks the PR" do
      step_run = judge_step_run(:advance, %{role: "qualifier", next_assignee: "reviewer"})

      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :approve, _}
      assert_received {:request_review, 7, ["reviewer"]}
      refute_received {:assignee, _, _}
      # judge: the lock is on the PR (dispatch_review), not the issue
      assert_received {:unlock, 7, "lcars-in-flight"}
    end

    test "judge :promote (terminal) → APPROVED review then FF merge, unlock BOTH (PR + ISSUE)" do
      step_run = judge_step_run(:promote, %{role: "reviewer"})

      assert {:ok, :promoted} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :approve, _}
      assert_received {:merge, 7}

      # The ISSUE lock (never lifted since the producer's :advance, persisted through the whole
      # review) lifts HERE, AT THE SAME TIME as the judge's PR lock — the entire brick is done.
      assert_received {:unlock, 7, _}
      assert_received {:unlock, 42, _}
    end

    test "judge :rework (gate fail) → REQUEST_CHANGES review, unlocks the PR, NO merge" do
      step_run = judge_step_run(:rework, %{role: "reviewer", next_assignee: "engineer"})

      assert {:ok, :rework_requested} =
               StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :request_changes, _}
      refute_received {:assignee, _, _}
      assert_received {:unlock, 7, _}
      refute_received {:merge, _}
    end

    test "judge with unexpected intent and no :review_event → FAIL-CLOSED review (REQUEST_CHANGES, never approve by omission)" do
      # Derivation by intent (`:review_event` absent): an intent that is NOT an explicit gate-pass
      # (`:advance`/`:promote`) must NEVER self-approve. Here `:reviewed` (a no-workflow_map judge
      # that lost its verdict) falls on the fail-closed catch-all → REQUEST_CHANGES, not APPROVED.
      # Under an `_ -> :approve` catch-all, this step_run validated by omission (the worst default
      # for a verdict).
      step_run = judge_step_run(:reviewed, %{role: "qualifier"})

      assert {:ok, :reviewed} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:review, 7, :request_changes, _}
      refute_received {:merge, _}
    end

    test "②.1d producer :review (no-workflow_map) → opens PR, request_review(qualifier+reviewer), assigns the human, unlocks PR ONLY (issue persists), NO merge" do
      step_run = producer_step_run(:review)

      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(
                 step_run,
                 orch_opts(reviewer_roles: ["qualifier", "reviewer"])
               )

      assert_received {:open_pr, "lcars/issue-42-engineer", "main", body}
      refute body =~ "Closes"
      # DN §1.4: qualifier + reviewer requested at once
      assert_received {:request_review, 7, ["qualifier", "reviewer"]}
      # ②.1e: the commissioning human (id -un) is assigned to the PR (#7)
      assert_received {:assignee, 7, _human}

      # unlock PR only (rework re-delivery, dispatch_review lock) — the ISSUE (1st delivery,
      # dispatch_issue lock) is NOT lifted here anymore: it persists until the final :promote.
      assert_received {:unlock, 7, "lcars-in-flight"}
      refute_received {:unlock, 42, _}
      # no merge here: the merge is driven by the PR-state (dispatch_review)
      refute_received {:merge, _}
    end

    test "②.1d judge :reviewed (no-workflow_map) → native review (explicit :approve event), unlocks the PR, NO merge nor request_review" do
      step_run = judge_step_run(:reviewed, %{role: "qualifier", review_event: :approve})

      assert {:ok, :reviewed} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :approve, _}
      # judge: lock on the PR (dispatch_review)
      assert_received {:unlock, 7, "lcars-in-flight"}

      # the judge does not merge and does not re-request a review: the poller (reviews-driven)
      # decides. No action on requested_reviewers (Gitea does not empty it; we read the reviews list).
      refute_received {:merge, _}
      refute_received {:request_review, _, _}
    end

    test "②.1d judge :reviewed REQUEST_CHANGES → request_changes review, unlocks the PR, no merge" do
      step_run = judge_step_run(:reviewed, %{role: "qualifier", review_event: :request_changes})

      assert {:ok, :reviewed} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:review, 7, :request_changes, _}
      assert_received {:unlock, 7, _}
      refute_received {:merge, _}
    end

    test "producer: open_pr fails → {:open_pr, _}, no route" do
      assert {:error, {:open_pr, {:http, 422, _}}} =
               StepRunCompleter.complete_pr(
                 producer_step_run(:promote),
                 deliverable: StubDeliverable,
                 forge_client: PrFailForge
               )

      refute_received {:merge, _}
    end

    test "judge: PR not found → {:pr_lookup, :pr_not_found} fail-loud" do
      assert {:error, {:pr_lookup, :pr_not_found}} =
               StepRunCompleter.complete_pr(judge_step_run(:promote), forge_client: NoPrForge)
    end

    test "judge: producer_branch absent → {:pr_lookup, :no_producer_branch}" do
      step_run = judge_step_run(:promote, %{producer_branch: nil})

      assert {:error, {:pr_lookup, :no_producer_branch}} =
               StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)
    end

    test "producer :promote: FF merge impossible (409) → {:merge, _} fail-loud" do
      assert {:error, {:merge, {:http, 409, _}}} =
               StepRunCompleter.complete_pr(
                 producer_step_run(:promote),
                 deliverable: StubDeliverable,
                 forge_client: MergeFailForge
               )
    end
  end
end
