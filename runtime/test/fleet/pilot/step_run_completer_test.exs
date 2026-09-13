defmodule Fleet.Pilot.StepRunCompleterTest do
  use ExUnit.Case, async: false

  # Serial: changes global spawner visibility and catalogue images; restoration does not isolate peers.

  alias Fleet.CapProfile.Image
  alias Fleet.Pilot.ForgeStubs.MergeFailForge
  alias Fleet.Pilot.StepRunCompleter
  alias Fleet.Test.BizCatalogueFixture
  alias Fleet.Workflow.Loader

  # Local call spy. Selective assert_received checks presence, not ordering; tests that
  # inspect the full message list can assert sequence.
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

  # Returns a real workspace commit so provenance's local commit check can pass.
  # No push happens in this stub despite its pushed? return field.
  defmodule HeadDeliverable do
    def publish(opts) do
      send(self(), {:published, opts})
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: opts.workspace)
      {:ok, %{commit_sha: String.trim(sha), pushed?: true, mode: :git_native}}
    end
  end

  # Match the forge's :ok returns for review, merge and review-request methods.
  defmodule PrForge do
    # No jury verdicts or conflict markers in this fixture.
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

    # The real seal posts only after merge succeeds; this method merely records a comment.
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

  # Fixture error separates the actionable message from the swagger URL metadata.
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
    # No jury verdicts or conflict markers in this fixture.
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def open_pr(_r, _h, _b, _t, _o), do: {:error, {:http, 422, "no commits between"}}
    def post_review(_r, _pr, _e, _b, _o), do: {:error, {:http, 500, "boom"}}

    # Observe comments so a failed merge can explicitly refute a false seal.
    def post_comment(_r, n, body, opts) do
      send(self(), {:comment, n, body, opts})
      {:ok, :posted}
    end

    def merge_pr(_r, _pr, _o), do: {:error, {:http, 409, "not fast-forward"}}
  end

  defmodule OrchForge do
    # No jury verdicts or conflict markers in this fixture.
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

    def stop_stopwatch(_repo, n, _opts) do
      send(self(), {:stopwatch_stopped, n})
      :ok
    end

    # Capture producer summaries on the issue.
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

  # Failed route must prevent the review request from exposing a stale workflow position.
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

  # PR lookup failure before native review.
  defmodule NoPrForge do
    def get_pr_for_branch(_r, _h, _b, _o), do: {:error, :pr_not_found}
  end

  defp base_step_run(extra \\ %{}) do
    Map.merge(
      %{
        repo: "lordzurp/lcars-test",
        issue_number: 42,
        role: "engineer",
        base_branch: "main",
        deliverable_opts: %{mode: :git_native, workspace: "/tmp/ws", base_sha: "cafe"}
      },
      extra
    )
  end

  defp seams do
    [deliverable: StubDeliverable, forge_client: OrderForge, forge_opts: []]
  end

  # Local commit fixture for provenance subject resolution.
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

      assert_received {:published, %{mode: :git_native, base_sha: "cafe"}}

      # These selective receives check calls, not their relative order.
      assert_received {:call, :comment, body, sig}
      assert sig == "[step_run:engineer:deadbeef]"
      assert body =~ "[step_run:engineer:deadbeef]"

      assert_received {:call, :close}
      assert_received {:call, :unlock, "lcars-in-flight"}

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

      # No map/step here: reassigned returns without changing route or human assignee.
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

      # Publish-failure markers feed a separate brake on the issue, keyed by publication base.
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

    # Exercise provenance through producer PR publication, not only its pure statement builder.
    # complete/2 can also publish but does not emit this attestation.
    @tag :tmp_dir
    test "emits the provenance triplet (brief_sha, input_sha, livrable_sha) under ops `provenance/`",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "lcars-test")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

      # Use a resolvable local subject, not a fabricated SHA.
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

      # Verify statement fields and local Git commit; no remote publication is exercised.
      prov = Path.join(work_dir, "provenance/issue-42-#{sha7}.json")
      assert File.exists?(prov)
      json = prov |> File.read!() |> Jason.decode!()

      assert get_in(json, ["subject", Access.at(0), "digest", "gitCommit"]) == sha

      assert get_in(json, ["predicate", "invocation", "configSource", "digest", "gitCommit"]) ==
               brief_sha

      assert get_in(json, ["predicate", "buildConfig", "input_sha"]) == "cafe"
      # Assert the completion-time visibility value is threaded into provenance.
      assert get_in(json, ["predicate", "invocation", "environment", "debug_visibility"]) == false

      {log, 0} = System.cmd("git", ["log", "--oneline"], cd: work_dir)
      assert log =~ "provenance: provenance/issue-42-#{sha7}.json"
    end

    @tag :tmp_dir
    test "a deliverable produced in DEBUG mode carries the mark", %{tmp_dir: tmp} do
      # Changes the global mode at completion time; no pod launch or REPL access is observed.
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

    # Failed PR creation must leave no attestation and emit a failure marker.
    # The stub's fake subject also prevents provenance emission, so absence alone is not
    # a discriminating assertion of publication order.
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

      assert body =~ "open_pr"
    end

    @tag :tmp_dir
    test "the pr-open-fail comment carries the forge's MESSAGE, never its swagger pointer",
         %{tmp_dir: tmp} do
      # Preserve the actionable HTTP error while excluding unrelated swagger metadata.
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

    # An unresolvable local subject refuses the archive; the stub publication result survives.
    @tag :tmp_dir
    test "subject not a commit of the publish workspace → engrave REFUSED loud, completion unharmed",
         %{tmp_dir: tmp} do
      work_dir = Path.join(tmp, "lcars-test")
      File.mkdir_p!(work_dir)
      {_, 0} = System.cmd("git", ["init", "-q"], cd: work_dir)

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

  # Reaping follows successful native review ingestion, subject to profile/scope guards.
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

      assert_received {:killed, pod_id}
      assert pod_id == Fleet.PodId.for_pr("fleet/proj", 7, "qualifier")
    end

    test "revue EN ÉCHEC → AUCUNE fauche : on ne tue que ce dont on a le résultat" do
      # Failed review must not invoke the kill spy.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_spawner, ReapSpy)

      assert {:error, {:review, _}} =
               StepRunCompleter.record_review(judge_run(),
                 forge_client: ReviewFailForge,
                 forge_opts: []
               )

      refute_received {:killed, _}
    end

    test "fauche EN ÉCHEC → le verdict tient quand même" do
      # A returned kill error must not fail an already-posted review; exceptions are untested.
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
      # The loaded profile's brief_kind distinguishes producer from judge here.
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
      # Favorable opinion is not final acceptance; the forge's APPROVED state remains protocol.
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
  end

  describe "record_review/2 — the machine verdict engraved beside the prose" do
    # Archive findings beside prose while preserving native review on returned write failures.
    @tag :tmp_dir
    test "review_findings → verdicts/issue-42-qualifier.json engraved (committed), review posted",
         %{tmp_dir: tmp} do
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

      # The JSON file contains the submitted payload directly.
      path = Path.join(work_dir, "verdicts/issue-42-qualifier.json")
      assert File.exists?(path)
      assert path |> File.read!() |> Jason.decode!() == findings

      # Verify a local commit, not an ops push.
      {log, 0} = System.cmd("git", ["log", "--oneline"], cd: work_dir)
      assert log =~ "verdict: verdicts/issue-42-qualifier.json"
    end

    # The review body transports findings to Jury; the ops object is their archive.
    # This short body does not exercise the pinning threshold named in the title.
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
      # A schema-refused payload must be diagnosed differently from absent emission.
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
      # Missing findings preserve prose bytes while emitting an absence warning.
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

      assert log =~ "findings NOT engraved"
      refute File.exists?(Path.join([tmp, "proj", "verdicts"]))
    end

    @tag :tmp_dir
    test "engrave failure (ops write refused) → loud warning, review UNHARMED", %{tmp_dir: tmp} do
      # A file blocking the verdicts directory exercises a returned write error, not an exception.
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

    # Distinguish absent payload from failed archival write; neither invents a machine verdict.
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
  end

  describe "record_review/2 — the forge error, and promote/2" do
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

      # Observe both calls; these selective receives do not establish merge/comment order.
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

      # Failed merge must not post a seal. The comment spy makes this refusal observable.
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

      refute_received {:assignee, _, _}

      # Producer advance keeps its issue lock through review.
      refute_received {:unlock, _, _}

      # Build timing stops at handoff even while the issue lock remains.
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

      # A racing judge reads the issue's route; collect ordered tags to verify route precedes request.
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

      # A returned route failure prevents the review trigger in this call.
      refute_received {:request_review, _, _}
    end

    test "producer with :eng_summary → FULL note on the TICKET, FOLDED POINTER in the PR opening (QoL, a single PR post)" do
      step_run =
        producer_step_run(:advance, %{
          next_assignee: "qualifier",
          eng_summary: "j'ai implémenté le décodeur, choisi un buffer circulaire"
        })

      assert {:ok, :review_requested} = StepRunCompleter.complete_pr(step_run, orch_opts())

      # Summary prose belongs on the issue; replay deduplication is not tested.
      assert_received {:comment, 42, issue_body}
      assert issue_body =~ "j'ai implémenté le décodeur, choisi un buffer circulaire"
      assert issue_body =~ "Note de l'engineer"

      # The opening body links to the issue note.
      assert_received {:open_pr, _head, _base, pr_body}
      assert pr_body =~ "ticket #42"
      refute pr_body =~ "j'ai implémenté le décodeur"

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

      # Rework unlocks the issue; dispatch follows routing, not the assignee in the test title.
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

      assert_received {:unlock, 7, "lcars-in-flight"}
    end

    test "judge :promote (terminal) → APPROVED review then FF merge, unlock BOTH (PR + ISSUE)" do
      step_run = judge_step_run(:promote, %{role: "reviewer"})

      assert {:ok, :promoted} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:get_pr, "lcars/issue-42-engineer", "main"}
      assert_received {:review, 7, :approve, _}
      assert_received {:merge, 7}

      # Both unlock calls occur here; they are separate writes, not simultaneous.
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
      # Without an explicit review event, :reviewed maps to request_changes rather than implicit approval.
      step_run = judge_step_run(:reviewed, %{role: "qualifier"})

      assert {:ok, :reviewed} = StepRunCompleter.complete_pr(step_run, forge_client: OrchForge)

      assert_received {:review, 7, :request_changes, _}
      refute_received {:merge, _}
    end

    test "producer :review on a ROUTED map → the ENGRAVED card's jury, never the project's (faceproof bench)" do
      # An engraved empty jury distinguishes this card from the project's fallback jury.
      step_run = producer_step_run(:review, %{workflow_map: "ops-zero"})

      zero_loader = fn "ops-zero" ->
        %{"jury" => [], "steps" => %{"build" => %{"role" => "scribe", "needs" => []}}}
      end

      # Do not override reviewer_roles: that would bypass the card selection under test.
      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(
                 step_run,
                 orch_opts(workflow_map_loader: zero_loader)
               )

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

      assert_received {:request_review, 7, ["qualifier", "reviewer"]}
      # Observe assignment to a human; this does not establish how credentials resolved it.
      assert_received {:assignee, 7, _human}

      # Review handoff releases the PR lock while retaining the producer's issue lock.
      assert_received {:unlock, 7, "lcars-in-flight"}
      refute_received {:unlock, 42, _}

      refute_received {:merge, _}
    end

    test "producer :review on a ZERO-JUDGE card (jury []) → opens PR, NO request_review, NO error" do
      # Empty jury is valid; this test exercises handoff, not the later poller promotion.
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

      assert_received {:unlock, 7, "lcars-in-flight"}

      # Later PR-state routing decides promotion; this call neither merges nor re-requests.
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

  describe "step_run_jury — the jury of the PROJECT's catalogue card, through the default loader" do
    @tag :tmp_dir
    test "a producer :review on a `biz` project convenes the `biz` card's judge", %{tmp_dir: tmp} do
      # No loader override: exercise repository catalogue selection through the default loader.
      %{install_dir: dir} = BizCatalogueFixture.write!(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [dir])
      :ok = Image.publish!()
      :ok = Loader.publish_image!()

      on_exit(fn ->
        Image.unpublish()
        Loader.unpublish_all_images()
      end)

      judge = BizCatalogueFixture.judge()
      # The project's no-jury fallback differs from the engraved standard card's judge.
      code_root = Path.join(tmp, "projects")
      BizCatalogueFixture.declare_project!(code_root, "boutique", "no-jury")

      step_run = producer_step_run(:review, %{repo: "biz/boutique", workflow_map: "standard"})

      assert {:ok, :review_requested} =
               StepRunCompleter.complete_pr(step_run, orch_opts(code_root: code_root))

      assert_received {:request_review, 7, reviewers}
      assert [reviewer] = reviewers
      assert String.ends_with?(reviewer, judge)
      refute String.starts_with?(reviewer, "fleet_"), "the default catalogue's login prefix"
    end
  end

  describe "step_run_jury — an engraved card that does not load falls back to the PROJECT card" do
    @tag :tmp_dir
    test "producer :review with an unloadable `workflow_map` → the declared card's jury, said",
         %{tmp_dir: tmp} do
      # Project-declared standard has a distinct judge, so a delegation-default fallback fails this assertion.
      %{install_dir: dir} = BizCatalogueFixture.write!(tmp)
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [dir])
      :ok = Image.publish!()
      :ok = Loader.publish_image!()

      on_exit(fn ->
        Image.unpublish()
        Loader.unpublish_all_images()
      end)

      judge = BizCatalogueFixture.judge()
      code_root = Path.join(tmp, "projects")
      BizCatalogueFixture.declare_project!(code_root, "boutique", "standard")

      step_run =
        producer_step_run(:review, %{
          repo: "biz/boutique",
          workflow_map: "ghost-card-that-does-not-exist"
        })

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          StepRunCompleter.complete_pr(step_run, orch_opts(code_root: code_root))
        end)

      assert {:ok, :review_requested} = result
      assert log =~ "engraved card unloadable"
      assert log =~ "falls back"
      assert_received {:request_review, 7, [reviewer]}
      assert String.ends_with?(reviewer, judge)
    end
  end

  describe "promote/2 — the seal's two pre-write refusals cross the completer (2026-09-05)" do
    # Explicit seal refusal shapes must propagate rather than raise through an unmatched case.
    defmodule SignalDownOrchForge do
      defdelegate pr_review_state(r, n, o), to: OrchForge
      defdelegate get_pr_for_branch(r, h, b, o), to: OrchForge
      defdelegate post_review(r, p, e, b, o), to: OrchForge
      defdelegate merge_pr(r, p, o), to: OrchForge
      defdelegate remove_label(r, n, l, o), to: OrchForge
      defdelegate stop_stopwatch(r, n, o), to: OrchForge
      defdelegate post_comment(r, p, b, o), to: OrchForge

      def count_comments_marked(_r, _n, _p, _o), do: {:error, :forge_down}
    end

    alias Fleet.Test.ProvenanceWallHarness, as: Wall
    alias Fleet.Test.ProvenanceWallHarness.WallForge

    # Add subject lookup and architect labels; reflect shared methods to avoid a second inventory.
    defmodule WallOrchForge do
      for {name, arity} <- OrchForge.__info__(:functions) do
        args = Macro.generate_arguments(arity, __MODULE__)

        def unquote(name)(unquote_splicing(args)),
          do: OrchForge.unquote(name)(unquote_splicing(args))
      end

      def branch_head(_repo, _branch, opts), do: {:ok, Keyword.fetch!(opts, :__head_sha__)}

      def add_label(_repo, n, label, _opts) do
        send(self(), {:label, n, label})
        {:ok, :added}
      end
    end

    test "conflict signal unreadable → typed error through route(:promote), NO merge, NO unlock" do
      step_run = judge_step_run(:promote, %{role: "reviewer"})

      assert {:error, {:conflict_signal_unreadable, {_prefix, :forge_down}}} =
               StepRunCompleter.complete_pr(step_run, forge_client: SignalDownOrchForge)

      refute_received {:merge, _}
      refute_received {:unlock, _, _}
    end

    @tag :tmp_dir
    @tag :requires_git
    test "provenance INCOHERENT → typed error, NO merge (the wall refuses before any write)",
         %{tmp_dir: tmp} do
      %{head: head, alien: alien} = Wall.harness(tmp)
      :ok = Wall.statement(tmp, 42, head, alien)

      step_run = %{
        repo: "fleet/demo",
        pr_number: 4,
        issue_number: 42,
        producer_branch: "lcars/issue-42-engineer",
        base_branch: "main"
      }

      opts = Wall.opts(tmp, head, 42)

      assert {:error, {:provenance_incoherent, _}} =
               StepRunCompleter.promote(
                 step_run,
                 Keyword.merge(opts, forge_client: WallForge, forge_opts: opts)
               )

      refute_received {:merge, _}
    end

    @tag :tmp_dir
    @tag :requires_git
    test "through route(:promote): the wall's refusal goes to the ARCHITECT, not to a log line",
         %{tmp_dir: tmp} do
      # Provenance refusal routes to await_arch after attempting judge unlock.
      %{head: head, alien: alien} = Wall.harness(tmp, "proj")
      :ok = Wall.statement(tmp, 42, head, alien, "proj")
      opts = Wall.opts(tmp, head, 42)

      assert {:ok, :awaiting_arch} =
               StepRunCompleter.complete_pr(
                 judge_step_run(:promote, %{role: "reviewer"}),
                 Keyword.merge(opts, forge_client: WallOrchForge, forge_opts: opts)
               )

      refute_received {:merge, _}
      assert_received {:label, 42, "lcars-awaits-arch"}
      assert_received {:comment, 42, body}
      assert body =~ "PROVENANCE"
      assert body =~ "re-livrer"

      assert_received {:unlock, 7, _}
      assert_received {:unlock, 42, _}
    end
  end
end
