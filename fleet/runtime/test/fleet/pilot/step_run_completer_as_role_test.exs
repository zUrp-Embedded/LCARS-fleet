defmodule Fleet.Pilot.StepRunCompleterAsRoleTest do
  # async: false — mutates the global `:role_tokens_dir` config (cf. Fleet.Credentials.RoleTokenTest).
  use ExUnit.Case, async: false

  alias Fleet.Pilot.StepRunCompleter

  @moduletag :tmp_dir

  # F-E6 — captures the `token` of the forge_opts passed to `post_comment`: the VERDICT comment must
  # be IN THE JUDGE'S NAME (role token), not the system account's. Labels stay system-signed (not
  # captured).
  defmodule TokenCaptureForge do
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
  end

  setup %{tmp_dir: tmp} do
    # resolvable consultant role token → `as_role("consultant")` must inject it.
    File.write!(Path.join(tmp, "consultant.gitea_token"), "tok-consultant")
    File.write!(Path.join(tmp, "reviewer.gitea_token"), "tok-reviewer")
    File.write!(Path.join(tmp, "engineer.gitea_token"), "tok-engineer")
    # B-04: a non-engineer producer (documentalist card) needs its own resolvable token.
    File.write!(Path.join(tmp, "documentalist.gitea_token"), "tok-documentalist")

    # :promote goes through `GatekeeperSeal.seal_and_merge` (fail-closed, soft-default #3) →
    # gatekeeper token required.
    File.write!(Path.join(tmp, "gatekeeper.gitea_token"), "tok-gatekeeper")
    Fleet.Pilot.TestEnv.put_env_restoring(:fleet_credentials, :role_tokens_dir, tmp)

    :ok
  end

  test "await_arch posts the verdict IN THE JUDGE'S NAME (role token overwrites the system)" do
    step_run = %{
      repo: "fleet/poc",
      issue_number: 3,
      role: "consultant",
      decision: "redirect",
      comment_body: "Verdict du consultant — redirect"
    }

    assert {:ok, :awaiting_arch} =
             StepRunCompleter.await_arch(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    # the base system token is OVERWRITTEN by the role token → forge author = Consultant (anti-masking).
    assert_received {:comment_token, "tok-consultant"}
  end

  test "complete: the step_run's signed comment is IN THE NAME OF THE finishing ROLE" do
    step_run = %{
      repo: "fleet/poc",
      issue_number: 1,
      role: "consultant",
      deliverable_opts: nil,
      step_run_sha: "brief-verdict",
      next_assignee: nil,
      comment_body: "Verdict du consultant — continue"
    }

    assert {:ok, :completed} =
             StepRunCompleter.complete(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    assert_received {:comment_token, "tok-consultant"}
  end

  test "judge :promote (terminal) → PR stopwatch stop signed JUDGE, ISSUE stopwatch stop signed PRODUCER" do
    step_run = %{
      repo: "fleet/proj",
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
  # feature branch, NOT the `Roles.producer_role` config global (a fixed "engineer"). A `documentalist`
  # card (docs into work/ops, not code into main) is the motivating case: pre-B-04 the ISSUE stopwatch
  # stop was signed "engineer" (config) → Gitea per-user refuses the mis-signed stop → the
  # documentalist's watch leaks forever. This is the SAME branch source the poller-driven promote
  # already reads (`ReviewLifecycle.promote_pr` — "no fork"); this test locks the workflow_map path onto it.
  test "judge :promote → ISSUE stopwatch stop signed by the CARD's producer (documentalist), not the config default" do
    step_run = %{
      repo: "fleet/docs-proj",
      issue_number: 99,
      role: "reviewer",
      pr_role: :judge,
      intent: :promote,
      next_assignee: nil,
      producer_branch: "lcars/issue-99-documentalist"
    }

    assert {:ok, :promoted} =
             StepRunCompleter.complete_pr(step_run,
               forge_client: TokenCaptureForge,
               forge_opts: [token: "system-token"]
             )

    # The ISSUE stopwatch (99) is stopped as DOCUMENTALIST — the producer the branch names — even
    # though `Roles.producer_role` defaults to "engineer". Pre-B-04 this asserted "tok-engineer".
    assert_received {:stop_stopwatch, 99, "tok-documentalist"}
  end
end
