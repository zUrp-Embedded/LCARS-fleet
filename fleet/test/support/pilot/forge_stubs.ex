defmodule Fleet.Pilot.ForgeStubs do
  @moduledoc """
  Shared ForgeClient stubs for pilot test files (B6 dedup): the two gatekeeper seal
  tests (`merge_and_promote_test` / `merge_and_promote_worktree_test`) and the completer
  (`step_run_completer_test`) each need the same OkForge / MergeFailForge.

  Spies: forge write-ops `send(self(), …)`. The caller (`merge_and_promote`, `complete_pr`)
  runs IN the test process (direct calls, no GenServer) → messages land in the test
  mailbox. A test that does not assert them ignores them at no cost.
  """

  defmodule OkForge do
    @moduledoc """
    Forge where everything succeeds. `post_comment` / `merge_pr` signal
    (`{:comment, repo, n, body, opts}` / `{:merge, repo, pr, opts}`) to prove the ORDER
    of the seal's writes and their SIGNATURE (the role token in `opts`).
    """
    # Real `ForgeClient.post_comment/4` shape = {:ok, :posted | :already}, NOT {:ok, 1}
    # (a numeric id is never returned — stub aligned).
    # A0 — the seal now reads the conflict signal before choosing its merge method. Default
    # stub answer: CLEAN PR (0 marks on every prefix) → method "rebase", the historic behavior.
    # Spied like the writes, so a test can assert the read happened.
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

    # The seal READS who approved before writing its closing comment (it must not claim verdicts
    # that do not exist). No jury here → empty verdicts, i.e. the zero-judge sentence.
    def get_route(_r, _n, _o), do: :none

    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    # WS2: the seal sets stage/merged post-merge — a load-bearing system trace. Its failure is NOT
    # dropped silently: `merge_and_promote` RETRIES it (bounded, `set_stage_merged_with_retry`) and logs
    # loud, since a lost stage/merged left the arch waiting forever on a merged brick (cf.
    # merge_and_promote.ex).
    #
    # ⚠ SIGNALE SES OPTS DEPUIS LA REVUE DU 2026-08-20. Il les avalait (`_opts`), donc RIEN
    # n'épinglait que ce label part sous le compte SYSTÈME et non sous un jeton de rail — mutation
    # survivante : substituer `merge_opts` à `forge_opts` violait WS1 en silence, suite verte. WS1
    # n'est pas une préférence : le chemin dégradé (`converge_out_of_band_merge`) n'a AUCUN jeton de
    # rôle et doit quand même pouvoir poser ce label, qui est la garde anti-redispatch.
    def set_stage(repo, n, stage, opts) do
      send(self(), {:set_stage, repo, n, stage, opts})
      {:ok, :posted}
    end

    # Explicit close: last act of merge_and_promote. SIGNALS (opts included): a test
    # (MergeAndPromoteTest) proves the close is signed by the DECISION rail — a close signed by the
    # system, or by the merge rail, would name an owner that did not promote.
    def close_issue(repo, n, opts) do
      send(self(), {:close_issue, repo, n, opts})
      {:ok, :closed}
    end
  end

  defmodule CloseFailForge do
    @moduledoc "Merge OK but `close_issue` FAILS — proves the seal LOGS LOUD (merged brick stays OPEN)."
    # A0 — the seal now reads the conflict signal before choosing its merge method. Default
    # stub answer: CLEAN PR (0 marks on every prefix) → method "rebase", the historic behavior.
    # Spied like the writes, so a test can assert the read happened.
    def count_comments_marked(repo, n, prefix, opts) do
      send(self(), {:count_marked, repo, n, prefix, opts})
      {:ok, 0}
    end

    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def merge_pr(_repo, _pr, _opts), do: :ok

    # The seal READS who approved before writing its closing comment (it must not claim verdicts
    # that do not exist). These stubs describe repos with no jury: empty verdicts, which is exactly
    # the zero-judge sentence the comment must print.
    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def close_issue(_repo, _n, _opts), do: {:error, {:http, 500, "close boom"}}
  end

  defmodule MergeFailForge do
    @moduledoc """
    Forge whose merge fails (`{:http, 409, "not fast-forward"}`). `post_comment` SIGNALS
    (`{:comment, repo, n, body, opts}`) → a test proves that NO « fusionnée » comment (the
    FR user-facing seal wording) is posted when the merge is KO
    (F-MERGE-CLAIM-BEFORE-REALITY) via `refute_received`. `open_pr` succeeds (`{:ok, 7}`):
    the completer `:promote` path opens the PR THEN fails at merge — the seal tests never
    call `open_pr` (harmless extra function).
    """
    # A0 — the seal now reads the conflict signal before choosing its merge method. Default
    # stub answer: CLEAN PR (0 marks on every prefix) → method "rebase", the historic behavior.
    # Spied like the writes, so a test can assert the read happened.
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

    # The seal READS who approved before writing its closing comment (it must not claim verdicts
    # that do not exist). These stubs describe repos with no jury: empty verdicts, which is exactly
    # the zero-judge sentence the comment must print.
    def pr_review_state(_repo, _n, _opts),
      do: {:ok, %{verdicts: %{}, reviewers: [], outcome: :no_jury}}

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
  end
end
