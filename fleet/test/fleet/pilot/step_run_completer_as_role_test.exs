defmodule Fleet.Pilot.StepRunCompleterAsRoleTest do
  # async: false — mutates the global `:role_tokens_dir` config (cf. Fleet.Credentials.RoleTokenTest).
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepRunCompleter

  @moduletag :tmp_dir

  # F-E6 — captures the `token` of the forge_opts passed to `post_comment`: the VERDICT comment must
  # be IN THE JUDGE'S NAME (role token), not the system account's. Labels stay system-signed (not
  # captured).
  defmodule TokenCaptureForge do
    # A0 — clean PR by default: the seal reads the conflict signal, 0 marks -> method "rebase".
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def post_comment(_repo, _n, _body, opts) do
      send(self(), {:comment_token, opts[:token]})
      {:ok, :posted}
    end

    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
    def start_stopwatch(_repo, _n, _opts), do: :ok

    # Captures (n, token) — proves that the stop of the ISSUE stopwatch (started by the PRODUCER,
    # persistent through the whole review) is PRODUCER-signed even when a JUDGE finishes the brick
    # (route(:promote)), while the stop of the PR stopwatch stays JUDGE-signed (its own review
    # turn). Two stops, two distinct identities, never conflated.
    def stop_stopwatch(_repo, n, opts) do
      send(self(), {:stop_stopwatch, n, opts[:token]})
      :ok
    end

    def close_issue(_repo, _n, _opts), do: {:ok, :closed}
    def post_route(_repo, _n, _workflow_map_name, _step, _opts), do: {:ok, :posted}

    def get_pr_for_branch(_repo, head, base, _opts),
      do: send(self(), {:get_pr, head, base}) && {:ok, 7}

    def post_review(_repo, pr, event, body, _opts),
      do: send(self(), {:review, pr, event, body}) && :ok

    def merge_pr(_repo, pr, _opts), do: send(self(), {:merge, pr}) && :ok
    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}

    # Read by the seal to name the accounts that approved before it writes its closing
    # comment (it must not claim verdicts that do not exist). No jury here -> empty.
    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}
  end

  setup %{tmp_dir: tmp} do
    # The DIRECTORY first: the fixture no longer spells the file name, it asks for the path the
    # runtime reads (`RoleIdentity.token_path/1`, keyed by the ACCOUNT), and that path is rooted here.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

    # resolvable scoper role token → `as_role("scoper")` must inject it.
    Fleet.TestEnv.put_role_token!("scoper", "tok-scoper")
    Fleet.TestEnv.put_role_token!("reviewer", "tok-reviewer")
    Fleet.TestEnv.put_role_token!("engineer", "tok-engineer")
    # B-04: a non-engineer producer (the doc rail's scribe) needs its own resolvable token.
    Fleet.TestEnv.put_role_token!("scribe", "tok-scribe")

    # :promote goes through `GatekeeperSeal.seal_and_merge` (fail-closed, soft-default #3) →
    # gatekeeper token required.
    Fleet.TestEnv.put_role_token!("gatekeeper", "tok-gatekeeper")

    :ok
  end

  test "await_arch posts the verdict IN THE JUDGE'S NAME (role token overwrites the system)" do
    step_run = %{
      repo: "fleet/poc",
      base_branch: "main",
      issue_number: 3,
      role: "scoper",
      decision: "redirect",
      comment_body: "Verdict du scoper — redirect"
    }

    assert {:ok, :awaiting_arch} =
             StepRunCompleter.await_arch(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    # the base system token is OVERWRITTEN by the role token → forge author = Consultant (anti-masking).
    assert_received {:comment_token, "tok-scoper"}
  end

  test "complete: the step_run's signed comment is IN THE NAME OF THE finishing ROLE" do
    step_run = %{
      repo: "fleet/poc",
      base_branch: "main",
      issue_number: 1,
      role: "scoper",
      deliverable_opts: nil,
      step_run_sha: "brief-verdict",
      next_assignee: nil,
      comment_body: "Verdict du scoper — continue"
    }

    assert {:ok, :completed} =
             StepRunCompleter.complete(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    assert_received {:comment_token, "tok-scoper"}
  end

  test "judge :promote (terminal) → PR stopwatch stop signed JUDGE, ISSUE stopwatch stop signed PRODUCER" do
    step_run = %{
      repo: "fleet/proj",
      base_branch: "main",
      issue_number: 42,
      role: "reviewer",
      pr_role: :judge,
      intent: :promote,
      next_assignee: nil,
      producer_branch: "lcars/issue-42-engineer"
    }

    assert {:ok, :promoted} =
             StepRunCompleter.complete_pr(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    # PR stopwatch (7): the JUDGE (reviewer) who just closed the brick started this stopwatch
    # itself (its own review turn) → stop signed WITH ITS OWN token.
    assert_received {:stop_stopwatch, 7, "tok-reviewer"}

    # ISSUE stopwatch (42): started by the PRODUCER at `dispatch_issue`, persistent through the
    # whole review — the stop MUST stay PRODUCER-signed (engineer), NEVER the finishing judge's role
    # (otherwise Gitea refuses the stop — per-user — and the engineer's stopwatch leaks forever).
    # Post-B-04 this identity comes from the branch (`lcars/issue-42-engineer`), not the config global.
    assert_received {:stop_stopwatch, 42, "tok-engineer"}
  end

  # B-04 (catalogue chantier 2026-07-20): the producer is whoever the CARD dispatched — read from the
  # feature branch, NOT the `Roles.producer_role` config global (a fixed "engineer"). A `scribe`
  # card (docs into ops, not code into main) is the motivating case: pre-B-04 the ISSUE stopwatch
  # stop was signed "engineer" (config) → Gitea per-user refuses the mis-signed stop → the
  # scribe's watch leaks forever. This is the SAME branch source the poller-driven promote
  # already reads (`ReviewLifecycle.promote_pr` — "no fork"); this test locks the workflow_map path onto it.
  test "judge :promote → ISSUE stopwatch stop signed by the CARD's producer (scribe), not the config default" do
    step_run = %{
      repo: "fleet/docs-proj",
      base_branch: "main",
      issue_number: 99,
      role: "reviewer",
      pr_role: :judge,
      intent: :promote,
      next_assignee: nil,
      producer_branch: "lcars/issue-99-scribe"
    }

    assert {:ok, :promoted} =
             StepRunCompleter.complete_pr(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    # The ISSUE stopwatch (99) is stopped as DOCUMENTALIST — the producer the branch names — even
    # though `Roles.producer_role` defaults to "engineer". Pre-B-04 this asserted "tok-engineer".
    assert_received {:stop_stopwatch, 99, "tok-scribe"}
  end

  # BL-6-34 — the measured bench signature: a producer role whose forge account/token does NOT
  # exist (the scoper lesson: a role added to the catalogue without its forge account loops in
  # role_token_unavailable). The deliverable is pushed, then the PR is refused FAIL-CLOSED between
  # push and PR-open — and the stall must be named ON the issue, posted with the SYSTEM token:
  # the missing ROLE token is exactly what the marker has to survive, or the ticket goes mute.
  test "producer WITHOUT role token → PR refused fail-closed, pr-open-fail marker under the SYSTEM token",
       %{tmp_dir: tmp} do
    # The setup provisions this producer, so the ABSENCE is staged here rather than by naming a role
    # nobody declares: a token directory that holds nothing. Naming a phantom role would prove the
    # wrong thing now — an unknown role has no ACCOUNT, so its refusal comes from the roster and not
    # from the missing credential this test is about.
    empty = Path.join(tmp, "no-tokens")
    File.mkdir_p!(empty)
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, empty)

    defmodule PushOnlyDeliverable do
      def publish(_opts), do: {:ok, %{commit_sha: "deadbeef", pushed?: true, mode: :git_native}}
    end

    defmodule MarkerCaptureForge do
      def post_comment(_repo, n, body, opts) do
        send(self(), {:marker, n, body, opts[:token]})
        {:ok, :posted}
      end
    end

    step_run = %{
      repo: "fleet/poc",
      issue_number: 9,
      role: "scribe",
      base_branch: "ops",
      deliverable_opts: %{
        mode: :git_native,
        workspace: "/tmp/ws",
        base_sha: "cafe",
        target_branch: "lcars/issue-9-scribe"
      }
    }

    assert {:error, :role_token_unavailable} =
             Fleet.Pilot.StepRunCompleter.open_deliverable_pr(step_run,
               deliverable: PushOnlyDeliverable,
               forge_client: MarkerCaptureForge,
               forge_opts: [token: "system-token"]
             )

    assert_received {:marker, 9, body, "system-token"}
    assert body =~ Fleet.Forge.Protocol.pr_open_fail_marker(9, "deadbeef")
    assert body =~ "role_token_unavailable"
    assert body =~ "lcars/issue-9-scribe"
  end

  describe "Emissions.post_eng_summary/2 — the note is a role's voice" do
    defmodule CountingForge do
      def post_comment(_repo, _n, body, _opts) do
        send(self(), {:posted, body})
        {:ok, :posted}
      end
    end

    test "a step_run with NO role posts nothing, and says so" do
      # The note carries a role's name AND is posted with that role's token. Defaulting the role
      # would sign one producer's summary as another's — the same refusal the missing-token path
      # already applies. Absence is skipped and LOGGED, never dressed up.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Fleet.Pilot.StepRunCompleter.Emissions.post_eng_summary(
                     %{repo: "org/repo", issue_number: 7, eng_summary: "done"},
                     forge_client: CountingForge
                   )
        end)

      refute_received {:posted, _}
      assert log =~ "carries no role"
      refute log =~ "engineer"
    end
  end
end
