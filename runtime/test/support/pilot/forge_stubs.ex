defmodule Fleet.Pilot.ForgeStubs do
  @moduledoc """
  Shared success, merge-failure and close-failure fixtures for Pilot tests.
  Spy messages go to `self()`: they reach the test mailbox when the operation
  runs directly in the test process. They record attempted calls, not forge state.
  """

  defmodule OkForge do
    @moduledoc """
    Successful operations with spies exposing write arguments and signing options.
    Ordering assertions must inspect message order, not only selective receipt.
    """
    # Zero conflict marks model a clean PR; post_comment returns :posted, not a numeric id.
    def count_comments_marked(repo, n, prefix, opts) do
      send(self(), {:count_marked, repo, n, prefix, opts})
      {:ok, 0}
    end

    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, :posted}
    end

    def merge_pr(repo, pr, opts) do
      send(self(), {:merge, repo, pr, opts})
      :ok
    end

    # Export pr_refs/3 so probe checks can resolve a head instead of taking the missing-capability path.
    def pr_refs(_repo, _pr, _opts),
      do: {:ok, %{head_sha: "deadbeef", head_ref: "feat", base_sha: "cafe", base_ref: "main"}}

    # No jury: closing prose must not invent approvals.
    def get_route(_r, _n, _o), do: :none

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    # Preserve opts in the spy: stage/merged uses system identity, including recovery
    # without a role token, and must not accidentally inherit merge identity.
    def set_stage(repo, n, stage, opts) do
      send(self(), {:set_stage, repo, n, stage, opts})
      {:ok, :posted}
    end

    # Preserve opts so tests can distinguish decision identity from system or merge identity.
    def close_issue(repo, n, opts) do
      send(self(), {:close_issue, repo, n, opts})
      {:ok, :closed}
    end
  end

  defmodule CloseFailForge do
    @moduledoc "Successful merge followed by persistent close errors; records close attempts."
    # Zero conflict marks model a clean PR.
    def count_comments_marked(repo, n, prefix, opts) do
      send(self(), {:count_marked, repo, n, prefix, opts})
      {:ok, 0}
    end

    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def merge_pr(_repo, _pr, _opts), do: :ok

    # No jury: closing prose must not invent approvals.
    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}

    # Records each close attempt for retry assertions.
    def close_issue(_repo, n, _opts) do
      send(self(), {:close_attempt, n})
      {:error, {:http, 500, "close boom"}}
    end
  end

  defmodule MergeFailForge do
    @moduledoc """
    Merge returns HTTP 409; comment spies let tests reject a premature success claim.
    PR creation succeeds so the completer's promote path can reach the failed merge.
    """
    # Zero conflict marks model a clean PR.
    def count_comments_marked(repo, n, prefix, opts) do
      send(self(), {:count_marked, repo, n, prefix, opts})
      {:ok, 0}
    end

    def open_pr(_repo, _head, _base, _title, _opts), do: {:ok, 7}

    def post_comment(repo, n, body, opts) do
      send(self(), {:comment, repo, n, body, opts})
      {:ok, :posted}
    end

    def merge_pr(_repo, _pr, _opts), do: {:error, {:http, 409, "not fast-forward"}}

    # No jury: closing prose must not invent approvals.
    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
  end
end
