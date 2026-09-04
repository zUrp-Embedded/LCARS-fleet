defmodule Fleet.Pilot.StepRunCompleterTest do
  use ExUnit.Case, async: false

  # SYNC on purpose: one test here flips the GLOBAL `:lcars_fleet, :spawner_debug_visibility`, which
  # every pod launch reads through `LaunchSpec.remote_control?/1`. Async peers would see the flip
  # mid-flight and decide a different visibility than they assert. Same lesson as the
  # `:require_onboarded` flake: restore-on-exit makes the value right AFTER the test and wrong
  # DURING it, for everyone else.

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

  # Returns the REAL HEAD of the workspace it publishes — the prod contract (`Deliverable.publish`
  # reads `head_sha(workspace)` post-push). The BL-6-34 belt checks the provenance subject against
  # that workspace: a hardcoded fake sha trips it by design, so the provenance-walking tests use
  # THIS stub over a real fixture repo.
  defmodule HeadDeliverable do
    def publish(opts) do
      send(self(), {:published, opts})
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: opts.workspace)
      {:ok, %{commit_sha: String.trim(sha), pushed?: true, mode: :git_native}}
    end
  end

  # PR-native forge stub: records the PR calls (send to the test). Returns the REAL
  # `ForgeClient` contract: `post_review`/`merge_pr`/`request_review` → `:ok` (not `{:ok, _}`).
  defmodule PrForge do
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def get_route(_r, _n, _o), do: :none

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

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

  # A forge answering in GITEA'S REAL SHAPE: the message a reader needs, plus the `url` pointer
  # Gitea attaches to every error body. The distinction is the subject of its test.
  defmodule GiteaShapedFailForge do
    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def open_pr(_r, _h, _b, _t, _o),
      do:
        {:error,
         {:http, 403,
          %{
            "message" => "user must be a collaborator",
            "url" => "http://forge:3000/api/swagger"
          }}}

    def post_comment(_r, n, body, opts) do
      send(self(), {:comment, n, body, opts})
      {:ok, %{"id" => 1}}
    end
  end

  defmodule PrFailForge do
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

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
    # Read by the seal before it names who approved (it must not claim verdicts that do not
    # exist). No jury in this stub -> empty verdicts.
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

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

    def post_route(_repo, _n, workflow_map, step, _opts) do
      send(self(), {:route, workflow_map, step})
      {:ok, :posted}
    end
  end

  # Same producer-advance surface as OrchForge, but post_route FAILS — proves the
  # state-first order fails SAFE (no review trigger ever fired on the stale route).
  defmodule RouteFailForge do
    def open_pr(_repo, _head, _base, _title, _opts), do: {:ok, 7}
    def stop_stopwatch(_repo, _n, _opts), do: :ok
    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def post_comment(_repo, _pr, _body, _opts), do: {:ok, :posted}

    def request_review(_repo, pr, reviewers, _opts) do
      send(self(), {:request_review, pr, reviewers})
      :ok
    end

    def post_route(_repo, _n, _workflow_map, _step, _opts), do: {:error, {:http, 500, "boom"}}
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
        # chantier face-projet : la face est assertee par le completer, la fixture la dit comme la prod
        base_branch: "main",
        deliverable_opts: %{mode: :git_native, workspace: "/tmp/ws", base_sha: "cafe"}
      },
      extra
    )
  end

  defp seams do
    [deliverable: StubDeliverable, forge_client: OrderForge, forge_opts: []]
  end

  # A real one-commit git repo standing for the publish workspace — its HEAD is what
  # `HeadDeliverable` returns and what the BL-6-34 belt verifies the subject against.
  defp init_workspace_repo!(tmp) do
    ws = Path.join(tmp, "ws-real")
    File.mkdir_p!(ws)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: ws)
    File.write!(Path.join(ws, "doc.md"), "contenu")
    {_, 0} = System.cmd("git", ["add", "."], cd: ws)

    {_, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "livrable"],
        cd: ws
      )

    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: ws)
    {ws, String.trim(sha)}
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

    test "publish fails → {:error, {:publish, _}}, NO PR opened — and the FAIL MARKER is recorded (frein-publish P2)" do
      opts = [deliverable: FailDeliverable, forge_client: PrForge, forge_opts: []]

      assert {:error, {:publish, :base_not_ancestor}} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)

      refute_received {:open_pr, _, _, _}

      # The ledger of the brake: one [publish-fail:issue-N:base-<sha12>] marker comment on the
      # ISSUE, carrying the gate base (deliverable_opts.base_sha "cafe"). Without it the brake
      # counts nothing and the loop is unbounded — this is the half the poster owns.
      assert_received {:comment, 42, body, _}
      assert body =~ Fleet.Forge.Protocol.publish_fail_marker(42, "cafe")
      assert body =~ ":base_not_ancestor"
    end

    test "frein-publish P2: a marker post that FAILS degrades to the error untouched (never a second failure mode)" do
      defmodule CommentFailForge2 do
        def post_comment(_r, _n, _b, _o), do: {:error, {:http, 500, "boom"}}
      end

      opts = [deliverable: FailDeliverable, forge_client: CommentFailForge2, forge_opts: []]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:publish, :base_not_ancestor}} =
                   StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)
        end)

      assert log =~ "publish-fail marker NOT recorded"
    end

    test "open_pr fails → {:error, {:open_pr, _}}" do
      opts = [deliverable: StubDeliverable, forge_client: PrFailForge, forge_opts: []]

      assert {:error, {:open_pr, {:http, 422, _}}} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)
    end

    # Regression: provenance hooked onto `complete/2` (verdicts WITHOUT deliverable) is never
    # emitted on the REAL producer path (`open_deliverable_pr` is the only publication point of a
    # git deliverable). This test walks that path and demands the full triplet — it would go red on
    # the wrong wiring. (The `:ops_root` seam replaces the untestable global
    # `Fleet.Layout.ops_root()`.)
    @tag :tmp_dir
    test "emits the provenance triplet (brief_sha, input_sha, livrable_sha) under ops `provenance/`",
         %{tmp_dir: tmp} do
      # the project's ops: project_name("lordzurp/lcars-test") = "lcars-test", a real git repo.
      work_dir = Path.join(tmp, "lcars-test")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      # real publish workspace: the subject sha is ITS head (BL-6-34 belt — a fake sha is refused).
      {ws, sha} = init_workspace_repo!(tmp)
      sha7 = String.slice(sha, 0, 7)

      brief_sha = String.duplicate("b", 40)

      step_run =
        pr_step_run(%{
          brief_sha: brief_sha,
          brief_ref: "briefs/issue-42-engineer.md",
          deliverable_opts: %{
            mode: :git_native,
            workspace: ws,
            base_sha: "cafe",
            target_branch: "feature/issue-42"
          }
        })

      opts = [deliverable: HeadDeliverable, forge_client: PrForge, forge_opts: [], ops_root: tmp]

      assert {:ok, %{commit_sha: ^sha}} = StepRunCompleter.open_deliverable_pr(step_run, opts)

      # The provenance appears, human-named on the issue (sha7 of the livrable), committed,
      # COMPLETE triplet.
      prov = Path.join(work_dir, "provenance/issue-42-#{sha7}.json")
      assert File.exists?(prov)
      json = prov |> File.read!() |> Jason.decode!()
      # (livrable, brief, input) = the 3 vertices of the triplet, each in its in-toto place.
      assert get_in(json, ["subject", Access.at(0), "digest", "gitCommit"]) == sha

      assert get_in(json, ["predicate", "invocation", "configSource", "digest", "gitCommit"]) ==
               brief_sha

      assert get_in(json, ["predicate", "buildConfig", "input_sha"]) == "cafe"
      # The builder's mode travels with the triplet — stated, not omitted, on the nominal path.
      assert get_in(json, ["predicate", "invocation", "environment", "debug_visibility"]) == false
      # committed, not just written on disk.
      {log, 0} = System.cmd("git", ["log", "--oneline"], cd: work_dir)
      assert log =~ "provenance: provenance/issue-42-#{sha7}.json"
    end

    @tag :tmp_dir
    test "a deliverable produced in DEBUG mode carries the mark", %{tmp_dir: tmp} do
      # The whole point of the stamp: an auditor reading this file must be able to tell that a
      # human could reach the pod's REPL while it worked. Asserting it end-to-end (and not only on
      # `statement/1`) is what pins the WIRING — the completer reading the mode at all.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :spawner_debug_visibility, true)

      work_dir = Path.join(tmp, "lcars-test")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      {ws, sha} = init_workspace_repo!(tmp)
      sha7 = String.slice(sha, 0, 7)

      step_run =
        pr_step_run(%{
          brief_sha: String.duplicate("b", 40),
          brief_ref: "briefs/issue-42-engineer.md",
          deliverable_opts: %{
            mode: :git_native,
            workspace: ws,
            base_sha: "cafe",
            target_branch: "feature/issue-42"
          }
        })

      opts = [deliverable: HeadDeliverable, forge_client: PrForge, forge_opts: [], ops_root: tmp]
      assert {:ok, %{commit_sha: ^sha}} = StepRunCompleter.open_deliverable_pr(step_run, opts)

      json =
        Path.join(work_dir, "provenance/issue-42-#{sha7}.json") |> File.read!() |> Jason.decode!()

      assert get_in(json, ["predicate", "invocation", "environment", "debug_visibility"]) == true
    end

    # BL-6-34 ordering pin: the engrave lives AFTER the PR is born. A completion that stalls
    # between push and PR must never leave a "delivered" attestation with no integration surface —
    # the measured signature was exactly that (branch on the forge, zero PR, provenance engraved,
    # ticket mute). The marker is the anti-mute half: the stall is named ON the issue.
    @tag :tmp_dir
    test "open_pr fails → NO provenance engraved + pr-open-fail marker on the issue (BL-6-34)",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "lcars-test")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      opts = [
        deliverable: StubDeliverable,
        forge_client: PrFailForge,
        forge_opts: [],
        ops_root: tmp
      ]

      assert {:error, {:open_pr, {:http, 422, _}}} =
               StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)

      refute File.exists?(Path.join(work_dir, "provenance"))

      assert_received {:comment, 42, body, _}
      assert body =~ Fleet.Forge.Protocol.pr_open_fail_marker(42, "deadbeef")
      assert body =~ "422"
      assert body =~ "feature/issue-42"

      # The OPERATION tag survives — it names which gesture failed, and a reader needs that.
      assert body =~ "open_pr"
    end

    @tag :tmp_dir
    test "the pr-open-fail comment carries the forge's MESSAGE, never its swagger pointer",
         %{tmp_dir: tmp} do
      # This comment is read by a human and by the architect. It used to paste `inspect/1` of the
      # raw reason, and Gitea puts a `"url" => ".../api/swagger"` in every error body — so the
      # pointer shipped into the message. Measured 2026-08-11 on a stalled PR: the signal was
      # `403 user must be a collaborator`, and the swagger URL was read as signal twice, once by a
      # human asking which forge it named and once inside an architect's root-cause analysis.
      # Noise that reaches a decision-maker is not neutral: it gets interpreted.
      work_dir = Path.join(tmp, "lcars-test")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      opts = [
        deliverable: StubDeliverable,
        forge_client: GiteaShapedFailForge,
        forge_opts: [],
        ops_root: tmp
      ]

      assert {:error, {:open_pr, _}} = StepRunCompleter.open_deliverable_pr(pr_step_run(), opts)

      assert_received {:comment, 42, body, _}
      assert body =~ "HTTP 403"
      assert body =~ "user must be a collaborator"
      refute body =~ "swagger"
      refute body =~ "api/swagger"
    end

    # BL-6-34 belt: a subject that is NOT a commit of the publish workspace is a proof from the
    # wrong point of view — the engrave is REFUSED loud, the completion itself is unharmed (the
    # deliverable is real and pushed; provenance stays best-effort, F-15).
    @tag :tmp_dir
    test "subject not a commit of the publish workspace → engrave REFUSED loud, completion unharmed",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "lcars-test")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      # real workspace whose HEAD is NOT the sha the stub claims ("deadbeef").
      {ws, _sha} = init_workspace_repo!(tmp)

      step_run =
        pr_step_run(%{
          deliverable_opts: %{
            mode: :git_native,
            workspace: ws,
            base_sha: "cafe",
            target_branch: "feature/issue-42"
          }
        })

      opts = [deliverable: StubDeliverable, forge_client: PrForge, forge_opts: [], ops_root: tmp]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{commit_sha: "deadbeef", pr_number: 7}} =
                   StepRunCompleter.open_deliverable_pr(step_run, opts)
        end)

      assert log =~ "engrave REFUSED"
      refute File.exists?(Path.join(work_dir, "provenance"))
    end
  end

  # ═══ B2 — LE POINT DE FAUCHE DU JUGE ═══
  #
  # La mort d'un juge était un EFFET DE BORD ; elle a maintenant un déclencheur causal, au même
  # étage du rail que celle du producteur (`MergeAndPromote.reap_ticket_producer/3`) : la revue
  # native est POSÉE, donc le livrable du juge est INGÉRÉ, donc le juge a fini.
  describe "B2 — la mort du juge est causée par l'ingestion de son verdict" do
    defmodule ReapSpy do
      @moduledoc false
      def kill_pod(pod_id) do
        send(self(), {:killed, pod_id})
        :ok
      end
    end

    defmodule ReapFails do
      @moduledoc false
      def kill_pod(_pod_id), do: {:error, :boom}
    end

    defmodule ReviewFailForge do
      @moduledoc false
      def post_review(_r, _pr, _e, _b, _o), do: {:error, {:http, 500, "nope"}}
    end

    defp judge_run,
      do: %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :approve
      }

    test "revue POSÉE → le pod du juge est fauché, et l'id se CONSTRUIT comme au dispatch" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, ReapSpy)

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(judge_run(), forge_client: PrForge, forge_opts: [])

      # `PodId.for_pr/3` — jamais une chaîne devinée. Un juge est clefé sur la PR, pas sur l'issue.
      assert_received {:killed, pod_id}
      assert pod_id == Fleet.PodId.for_pr("fleet/proj", 7, "qualifier")
    end

    test "revue EN ÉCHEC → AUCUNE fauche : on ne tue que ce dont on a le résultat" do
      # ⚠ LA MOITIÉ QUI COMPTE. Faucher avant que la revue tienne perdrait le verdict ET son
      # auteur : le rail rejoue sur `{:error, {:review, _}}`, et il rejouerait dans le vide.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, ReapSpy)

      assert {:error, {:review, _}} =
               StepRunCompleter.record_review(judge_run(),
                 forge_client: ReviewFailForge,
                 forge_opts: []
               )

      refute_received {:killed, _}
    end

    test "fauche EN ÉCHEC → le verdict tient quand même" do
      # Un pod qui survit est un coût, pas une corruption. Rendre une erreur ici ferait rejouer une
      # revue DÉJÀ POSÉE — on transformerait une place perdue en double verdict.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, ReapFails)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :reviewed} =
                   StepRunCompleter.record_review(judge_run(),
                     forge_client: PrForge,
                     forge_opts: []
                   )
        end)

      assert log =~ "NOT reaped"
    end

    test "un PRODUCTEUR qui passerait par ce chemin n'est PAS fauché ici" do
      # La garde lit `brief_kind`, pas un nom de rôle : la mort du producteur appartient au sceau,
      # à la fusion, pas à une revue. Deux morts, deux causes, et elles ne se recouvrent pas.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, ReapSpy)

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(%{judge_run() | role: "engineer"},
                 forge_client: PrForge,
                 forge_opts: []
               )

      refute_received {:killed, _}
    end
  end

  describe "record_review/2 + promote/2 (PR-native)" do
    test "verdict :approve → native APPROVED review (role-generated body)" do
      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :approve
      }

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(step_run, forge_client: PrForge, forge_opts: [])

      assert_received {:review, 7, :approve, body}
      assert body =~ "qualifier"
      # "APPROUVÉ" pins the FR user-facing review body.
      # ⚖ TAXONOMIE : un juge rend un AVIS (tag JUDGED — « jamais acceptation seule »), il
      # n'approuve pas. L'état de la review sur la forge reste `APPROVED` — c'est le protocole, et
      # la branch-protection les compte — mais la prose lue par un humain ne doit pas attribuer au
      # juge un acte qui appartient au rail.
      assert body =~ "AVIS FAVORABLE"

      refute body =~ "APPROUVÉ",
             "le mot d'acceptation appartient au seal, pas au juge"
    end

    test "verdict :request_changes with explicit body" do
      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        base_branch: "main",
        role: "reviewer",
        review_event: :request_changes,
        review_body: "il manque un test de la branche d'erreur"
      }

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(step_run, forge_client: PrForge, forge_opts: [])

      assert_received {:review, 7, :request_changes, "il manque un test de la branche d'erreur"}
    end

    # C1 2026-08-18 — the MACHINE verdict: a build-validated `details.findings` rides the
    # step_run as `:review_findings` and lands as `verdicts/issue-<n>-<role>.json`, committed in
    # the ops worktree next to the prose pin. Best-effort like the provenance triplet: every
    # degradation below posts the review anyway and RECORDS the absence loud.
    @tag :tmp_dir
    test "review_findings → verdicts/issue-42-qualifier.json engraved (committed), review posted",
         %{tmp_dir: tmp} do
      # the project's ops face: project_name("fleet/proj") = "proj", a real git repo.
      work_dir = Path.join(tmp, "proj")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      findings = %{
        "findings" => [%{"severity" => "minor", "description" => "naming"}],
        "score" => 9
      }

      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :approve,
        review_findings: findings
      }

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(step_run,
                 forge_client: PrForge,
                 forge_opts: [],
                 ops_root: tmp
               )

      assert_received {:review, 7, :approve, _body}

      # The object on disk IS the validated payload — nothing wrapped, nothing fabricated: the
      # path carries (issue, role), git carries the identity, the file carries the judge's words.
      path = Path.join(work_dir, "verdicts/issue-42-qualifier.json")
      assert File.exists?(path)
      assert path |> File.read!() |> Jason.decode!() == findings

      # committed, not just written: an uncommitted machine verdict has no citable identity.
      {log, 0} = System.cmd("git", ["log", "--oneline"], cd: work_dir)
      assert log =~ "verdict: verdicts/issue-42-qualifier.json"
    end

    # C2 2026-08-19 — le MÊME payload part aussi SUR LA REVIEW. L'objet gravé est l'archive ; le
    # corps de la review est le TRANSPORT que le gate consomme (`Jury` fetch déjà tous les corps).
    @tag :tmp_dir
    test "review_findings → le corps posté PORTE le bloc machine, hors du résumé", %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "proj")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      findings = %{"findings" => [%{"severity" => "important", "description" => "faux-vert"}]}

      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :request_changes,
        review_body: "Le test passe sans rien prouver.",
        review_findings: findings
      }

      assert {:ok, :reviewed} =
               StepRunCompleter.record_review(step_run,
                 forge_client: PrForge,
                 forge_opts: [],
                 ops_root: tmp
               )

      assert_received {:review, 7, :request_changes, body}

      assert {:ok, ^findings} = Fleet.FindingsWire.parse(body),
             "le gate relit le payload dans le corps même de la review"

      assert body =~ "Le test passe sans rien prouver.",
             "et la prose du juge reste intacte devant : le bloc s'ajoute, il ne remplace pas"
    end

    test "un juge dont le payload a été REFUSÉ n'est pas accusé de s'être tu" do
      # MESURÉ AU BANC (2026-08-19, probe-rails#47) : sur trois émissions, DEUX refusées par le
      # schéma — un `findings` sérialisé en chaîne, un `severity_max: "none"` hors énumération.
      # Le log d'absence les rangeait toutes deux en « ce juge n'a rien envoyé », et cette phrase
      # m'a envoyé chercher pendant des heures pourquoi les juges se taisaient — alors qu'ils
      # parlaient. Un rail qui nomme mal la panne qu'il observe coûte plus cher qu'un rail muet.
      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :approve,
        review_body: "Prose.",
        review_findings_refused: true
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :reviewed} =
                   StepRunCompleter.record_review(step_run, forge_client: PrForge, forge_opts: [])
        end)

      assert log =~ "DID submit details.findings"
      assert log =~ "REFUSED upstream"

      refute log =~ "submitted NO details.findings",
             "le juge a émis : l'accuser de silence envoie corriger le mauvais bout"
    end

    test "un juge SANS verdict machine poste le corps d'aujourd'hui, et son silence est DIT" do
      # Deux propriétés en un test, parce qu'elles sont le même arbitrage : la compat est
      # byte-for-byte (un juge qui n'émet rien ne voit pas sa review changer), MAIS l'absence
      # cesse d'être muette. Mesuré au banc le 2026-08-19 : un qualifier a rendu un excellent
      # verdict et zéro payload machine, sans qu'une ligne le dise nulle part — et c'est
      # exactement ce qui affamerait la fonction d'agrégation qui vient.
      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :approve,
        review_body: "Rien à redire."
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :reviewed} =
                   StepRunCompleter.record_review(step_run, forge_client: PrForge, forge_opts: [])
        end)

      assert_received {:review, 7, :approve, body}
      assert body == "Rien à redire.", "aucun octet ajouté quand il n'y a rien à transporter"
      assert log =~ "NO details.findings"
      assert log =~ "qualifier"
    end

    @tag :tmp_dir
    test "no ops face → NO machine file, review posts, the absence is RECORDED loud", %{
      tmp_dir: tmp
    } do
      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :approve,
        review_findings: %{"findings" => []}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :reviewed} =
                   StepRunCompleter.record_review(step_run,
                     forge_client: PrForge,
                     forge_opts: [],
                     ops_root: tmp
                   )
        end)

      assert_received {:review, 7, :approve, _body}
      # Same doctrine as the provenance {:work_dir_missing, _}: the missing record says so.
      assert log =~ "findings NOT engraved"
      refute File.exists?(Path.join([tmp, "proj", "verdicts"]))
    end

    @tag :tmp_dir
    test "engrave failure (ops write refused) → loud warning, review UNHARMED", %{tmp_dir: tmp} do
      # A `verdicts` regular FILE where the subdir must go: OpsObject's mkdir_p returns
      # {:error, _} — a clean commit failure, no raise, exercising the degraded branch.
      work_dir = Path.join(tmp, "proj")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)
      File.write!(Path.join(work_dir, "verdicts"), "not a directory")

      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :approve,
        review_findings: %{"findings" => []}
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :reviewed} =
                   StepRunCompleter.record_review(step_run,
                     forge_client: PrForge,
                     forge_opts: [],
                     ops_root: tmp
                   )
        end)

      assert_received {:review, 7, :approve, _body}
      assert log =~ "findings NOT engraved"
    end

    # ⚠ CE TEST A CHANGÉ DE VERDICT LE 2026-08-19, ET C'EST UN RENVERSEMENT ASSUMÉ. Il s'appelait
    # « no machine file and NO noise (the legacy judge is nominal) » et épinglait le silence : au
    # 18 août, `findings` venait de naître, aucun SP ne le nommait, et un juge qui n'en émettait
    # pas était un juge legacy — un cas NOMINAL, que rien ne devait accuser.
    #
    # Ce qui a changé n'est pas l'avis, c'est le monde : tous les SP de juge composent désormais la
    # consigne. Une absence ne dit plus « ce juge n'a jamais entendu parler de la clé », elle dit
    # « on lui a demandé et il ne l'a pas fait » — mesuré au banc le 2026-08-19 (PR#34 : verdict
    # excellent, zéro payload, zéro trace). Le fichier machine reste absent (rien à graver) ; ce
    # qui devient faux, c'est le silence.
    @tag :tmp_dir
    test "no review_findings → toujours aucun fichier machine, mais l'absence est DITE", %{
      tmp_dir: tmp
    } do
      work_dir = Path.join(tmp, "proj")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :approve
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :reviewed} =
                   StepRunCompleter.record_review(step_run,
                     forge_client: PrForge,
                     forge_opts: [],
                     ops_root: tmp
                   )
        end)

      refute File.exists?(Path.join(work_dir, "verdicts/issue-42-qualifier.json")),
             "rien à graver : c'est l'ABSENCE de payload, pas un échec de gravure"

      assert log =~ "NO details.findings"

      refute log =~ "NOT engraved",
             "et surtout PAS le message d'échec de gravure : ne rien avoir à écrire n'est pas " <>
               "avoir échoué à écrire, et confondre les deux enverrait chercher une panne d'ops"
    end

    test "record_review propagates the forge error" do
      step_run = %{
        repo: "fleet/proj",
        issue_number: 42,
        pr_number: 7,
        role: "qualifier",
        review_event: :approve
      }

      assert {:error, {:review, {:http, 500, _}}} =
               StepRunCompleter.record_review(step_run, forge_client: PrFailForge, forge_opts: [])
    end

    test "promote → gatekeeper comment + FF merge, {:ok, :promoted}" do
      step_run = %{
        repo: "fleet/proj",
        pr_number: 7,
        base_branch: "main",
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
        base_branch: "main",
        issue_number: 42,
        producer_branch: "lcars/issue-42-engineer"
      }

      assert {:error, {:merge, {:http, 409, _}}} =
               StepRunCompleter.promote(step_run, forge_client: PrFailForge, forge_opts: [])

      # Invariant F-MERGE-CLAIM-BEFORE-REALITY: the seal is MERGE-FIRST → a 409 merge must leave NO
      # "sealed/merged" comment on the issue (commenting before confirmation would freeze a success
      # that never happened). PrFailForge SIGNALS its comments → this refute is probative (it would
      # break on a comment-before-merge regression, the exact bug MergeAndPromote avoids).
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
          base_branch: "main",
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
          base_branch: "main",
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

    test "advance is STATE-FIRST: the route engraves BEFORE the review trigger (order load-bearing)" do
      step_run =
        producer_step_run(:advance, %{
          next_assignee: "qualifier",
          workflow_map: "gk-smoke",
          next_step: "review"
        })

      assert {:ok, :review_requested} = StepRunCompleter.complete_pr(step_run, orch_opts())

      # The dispatched judge derives its map position from the ISSUE's engraved route:
      # trigger-first exposed it to the PREVIOUS step on any racing tick (off-map
      # resolution, soft gates never evaluated). Mailbox order IS call order.
      {:messages, msgs} = Process.info(self(), :messages)

      calls =
        for m <- msgs, is_tuple(m) and elem(m, 0) in [:route, :request_review], do: elem(m, 0)

      assert calls == [:route, :request_review]
    end

    test "a failed post_route fails SAFE: no review trigger ever fired on the stale route" do
      step_run =
        producer_step_run(:advance, %{
          next_assignee: "qualifier",
          workflow_map: "gk-smoke",
          next_step: "review"
        })

      assert {:error, {:route, {:http, 500, _}}} =
               StepRunCompleter.complete_pr(step_run, orch_opts(forge_client: RouteFailForge))

      # Trigger-first used to LAY the review request and THEN fail the route: the judge
      # evaluated the previous step deterministically. State-first leaves the brick
      # stuck-but-consistent — lock held, no judge, the error visible.
      refute_received {:request_review, _, _}
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

    test "producer :review on a ROUTED map → the ENGRAVED card's jury, never the project's (faceproof bench)" do
      # chantier face-projet: the step_run carries the engraved map (workshop-direct, jury []) — the
      # review request must convene THAT card's jury, not the project card's. Reading the project
      # card laid brief-gate's qualifier+reviewer onto a zero-judge ops PR: REQUEST_CHANGES x2 on
      # prose, rework loop. Measured on the faceproof bench before this test existed.
      step_run = producer_step_run(:review, %{workflow_map: "ops-zero"})

      zero_loader = fn "ops-zero" ->
        %{"jury" => [], "steps" => %{"build" => %{"role" => "scribe", "needs" => []}}}
      end

      # NO reviewer_roles seam here — it would win over both cards and prove nothing. The
      # discriminant is real: without the fix, the fallback `project_jury` loads the delegation
      # default card (brief-gate, jury qualifier+reviewer) and a request_review fires.
      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(
                 step_run,
                 orch_opts(workflow_map_loader: zero_loader)
               )

      # Zero-judge engraved card → NOBODY convened. The promote is dispatch_review's (:no_jury).
      refute_received {:request_review, _, _}
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

    test "producer :review on a ZERO-JUDGE card (jury []) → opens PR, NO request_review, NO error" do
      # An empty jury is a DELIBERATE card choice (schema doctrine), not a config hole:
      # nothing to request here — the poller seals directly on its next tick
      # (`dispatch_by_verdicts` zero-judge path). The rest of the hand-off is unchanged
      # (human assigned, PR lock lifted, no merge on this side).
      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(
                 producer_step_run(:review),
                 orch_opts(reviewer_roles: [])
               )

      assert_received {:open_pr, "lcars/issue-42-engineer", "main", _}
      refute_received {:request_review, _, _}
      assert_received {:assignee, 7, _human}
      assert_received {:unlock, 7, "lcars-in-flight"}
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
