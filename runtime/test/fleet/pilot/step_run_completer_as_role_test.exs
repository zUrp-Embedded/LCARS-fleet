defmodule Fleet.Pilot.StepRunCompleterAsRoleTest do
  # Serial: changes credentials_role_tokens_dir globally.
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepRunCompleter

  @moduletag :tmp_dir

  # Capture role-token options for comments; label signing is not observed.
  defmodule TokenCaptureForge do
    def count_comments_marked(_repo, _n, _prefix, _opts), do: {:ok, 0}

    def post_comment(_repo, _n, _body, opts) do
      send(self(), {:comment_token, opts[:token]})
      {:ok, :posted}
    end

    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
    def start_stopwatch(_repo, _n, _opts), do: :ok

    # Capture PR/judge vs issue/producer timer identities independently.
    def stop_stopwatch(_repo, n, opts) do
      send(self(), {:stop_stopwatch, n, opts[:token]})
      :ok
    end

    def close_issue(_repo, _n, _opts), do: {:ok, :closed}
    def post_route(_repo, _n, _workflow_map_name, _step, _opts), do: {:ok, :posted}

    def get_pr_for_branch(_repo, head, base, _opts) do
      send(self(), {:get_pr, head, base})
      {:ok, 7}
    end

    def post_review(_repo, pr, event, body, _opts) do
      send(self(), {:review, pr, event, body})
      :ok
    end

    def merge_pr(_repo, pr, _opts) do
      send(self(), {:merge, pr})
      :ok
    end

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}

    def get_route(_r, _n, _o), do: :none

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}
  end

  setup %{tmp_dir: tmp} do
    # Root the account-keyed token paths before writing fixtures.
    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tmp)

    Fleet.TestEnv.put_role_token!("scoper", "tok-scoper")
    Fleet.TestEnv.put_role_token!("reviewer", "tok-reviewer")
    Fleet.TestEnv.put_role_token!("engineer", "tok-engineer")

    Fleet.TestEnv.put_role_token!("scribe", "tok-scribe")

    # Chief merges; gatekeeper promotes, requiring separate credentials.
    Fleet.TestEnv.put_role_token!("gatekeeper", "tok-gatekeeper")
    Fleet.TestEnv.put_role_token!("chief", "tok-chief")

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

    # The PR watch belongs to this judge's review turn.
    assert_received {:stop_stopwatch, 7, "tok-reviewer"}

    # The issue watch belongs to the producer named by the branch, not the finishing judge.
    assert_received {:stop_stopwatch, 42, "tok-engineer"}
  end

  # A scribe producer distinguishes branch-derived identity from the default engineer.
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

    assert_received {:stop_stopwatch, 99, "tok-scribe"}
  end

  # A post-publication credential failure must remain visible with caller/system credentials.
  test "producer WITHOUT role token → PR refused fail-closed, pr-open-fail marker under the SYSTEM token",
       %{tmp_dir: tmp} do
    # Use a declared role with no token: a phantom role would test roster resolution instead.
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
             StepRunCompleter.open_deliverable_pr(step_run,
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
      # No role means no invented identity for a summary.
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
