defmodule Fleet.Pilot.ForgeClient.Jury do
  @moduledoc """
  Reads the **jury state** of a PR (native Gitea reviews) — sub-domain of `Fleet.Pilot.ForgeClient`.
  Self-contained concern: it reads ONLY `GET .../pulls/{index}/reviews` and derives verdicts/jury/feedback
  from it; it calls no other forge op (zero coupling to the issues/PR core). `ForgeClient` forwards these
  functions (the module injected by the `:forge_client` seam stays `ForgeClient`; the implementation lives here).

  The domain subtlety — why this is NOT trivial — is the **commit-scoping** and the fact that
  Gitea's `requested_reviewers` is VOLATILE: the jury's source of truth is the list of review-records,
  not the requested field. Details in each `@doc`.

  **Last revised**: 2026-07-18
  """

  import Fleet.Pilot.ForgeClient.Transport, only: [resolve_config: 1, http_get: 2, paginate: 3]

  # Safe encoding of URL segments (path-traversal lock) — single authority UrlSafe.
  import Fleet.Pilot.ForgeClient.UrlSafe, only: [encode_repo: 1]

  @doc """
  Review verdict **PER judge** of a PR (Gitea `GET /repos/{repo}/pulls/{index}/reviews`): the
  LAST decisive non-dismissed review of EACH reviewer, key = **downcased** login.

  **Why per-judge and not `requested_reviewers`**: Gitea 1.26 does NOT clear `requested_reviewers`
  when a judge has reviewed, and the DELETE is a no-op on an already-active reviewer → we
  CANNOT rely on it to know "who is left to judge". The SOURCE OF TRUTH = the list of
  reviews: a judge has a **decisive verdict** iff its last non-dismissed review is APPROVED or
  REQUEST_CHANGES. The poller dispatches a requested judge that does NOT yet have a verdict, and decides
  (merge/rework) when all the requested ones have one.

  **Commit-scoping (`:head_sha`)**: a verdict is only valid for the COMMIT it judged. Passing
  `head_sha: pr.head.sha` (prod path) → only reviews `commit_id == head_sha` count; a review
  on an earlier commit is STALE (the code no longer exists). Crucial for REQUEST_CHANGES: Gitea
  NEVER dismisses it on push (≠ stale approvals, dismissed by branch-protection) — without scoping, a
  stale REQUEST_CHANGES stays "active", its judge is never re-dispatched (it already has a verdict) and the
  PR would loop in infinite rework. Scoping makes it `pending` → re-judged on the current code.
  COMMENT/PENDING/REQUEST_REVIEW reviews are NOT decisive (ignored).

  ## Returns
    * `{:ok, %{"qualifier" => :approved, "reviewer" => :changes_requested, ...}}` — login(↓) → verdict
    * `{:ok, %{}}` — no decisive review
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec pr_review_verdicts(String.t(), integer(), Keyword.t()) ::
          {:ok, %{optional(String.t()) => :approved | :changes_requested}} | {:error, term()}
  def pr_review_verdicts(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    # "Verdicts only" projection of `pr_review_state` (factored: a single fetch, a single
    # scoping/last-review logic). Kept for callers that don't need the jury SET (pod_tools).
    with {:ok, %{verdicts: verdicts}} <- pr_review_state(repo, index, opts), do: {:ok, verdicts}
  end

  @doc """
  Jury state of a PR in ONE fetch (`GET .../pulls/{index}/reviews`): `verdicts` (decisive per judge,
  commit-scoped via `:head_sha` — cf. `pr_review_verdicts`) AND `reviewers` (the jury SET).

  **The jury SET is NOT read from `pr.requested_reviewers`**: that field is VOLATILE (Gitea
  alters it unreliably — a judge can DISAPPEAR from it without having voted, which would merge on a
  half-jury). STABLE source = the review-records, which persist: a `REQUEST_REVIEW` =
  "this judge was requested"; an `APPROVED`/`REQUEST_CHANGES` = "it voted". The caller (`dispatch_review`)
  unions with `requested_reviewers` (defensive) and computes `pending = jury -- verdicts` → a
  never-voted judge stays `pending` (spawned), NEVER skipped.

  ## Returns
    * `{:ok, %{verdicts: %{login↓ => :approved | :changes_requested}, reviewers: [login↓]}}`
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec pr_review_state(String.t(), integer(), Keyword.t()) ::
          {:ok,
           %{
             verdicts: %{optional(String.t()) => :approved | :changes_requested},
             reviewers: [String.t()]
           }}
          | {:error, term()}
  def pr_review_state(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    head_sha = Keyword.get(opts, :head_sha)

    with {:ok, config} <- resolve_config(opts),
         {:ok, reviews} when is_list(reviews) <-
           http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews") do
      {:ok,
       %{verdicts: verdicts_by_reviewer(reviews, head_sha), reviewers: jury_reviewers(reviews)}}
    else
      # F-C069 — a 2xx with a NON-LIST body (a proxy/gateway serving an HTML page or an object envelope
      # with 200) is fail-LOUD, NEVER an `{:ok, empty}`: an empty jury here → `dispatch_by_verdicts([], %{})`
      # → the MERGE branch (merge on a lost/empty jury). Mirror of `paginate`'s `:unexpected_page_shape`.
      {:ok, non_list} ->
        {:error,
         {:unexpected_review_shape, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews",
          non_list}}

      {:error, _} = err ->
        err
    end
  end

  # The jury SET = every login with a "jury" review-record: requested (`REQUEST_REVIEW`) OR
  # having voted (`APPROVED`/`REQUEST_CHANGES`). Excludes `COMMENT`/`PENDING` (non-jury noise). STABLE source
  # (the records persist) vs volatile `requested_reviewers` → a judge dropped from the field without voting stays
  # in the jury → `pending` → spawned, no more merge on a half-jury.
  defp jury_reviewers(reviews) do
    reviews
    |> Enum.filter(&(&1["state"] in ["REQUEST_REVIEW", "APPROVED", "REQUEST_CHANGES"]))
    |> Enum.map(&(get_in(&1, ["user", "login"]) |> to_string() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Last decisive review PER reviewer (downcased login → verdict atom). Gitea lists in creation
  # order → `List.last` of a group = that reviewer's IN-FORCE review. When `head_sha` is provided
  # (prod path, set by `dispatch_review` from `pr.head.sha`), a verdict is **COMMIT-SCOPED**: only
  # the one placed on the CURRENT commit (`commit_id == head_sha`) counts; a review on an earlier commit
  # is STALE — the judged code no longer exists, the judge must re-judge. Indispensable because Gitea does
  # NOT dismiss a REQUEST_CHANGES on push (only stale approvals via branch-protection are): without this
  # filter, a stale REQUEST_CHANGES that is never re-dispatched blocks the PR FOREVER.
  defp verdicts_by_reviewer(reviews, head_sha) do
    reviews
    |> Enum.reject(&Map.get(&1, "dismissed", false))
    |> Enum.filter(&(&1["state"] in ["APPROVED", "REQUEST_CHANGES"]))
    |> reject_stale_reviews(head_sha)
    |> Enum.group_by(&(get_in(&1, ["user", "login"]) |> to_string() |> String.downcase()))
    |> Map.new(fn {login, revs} -> {login, decisive_verdict(List.last(revs)["state"])} end)
  end

  # `head_sha == nil` (low-level / legacy callers) → no scoping. Otherwise: strict `commit_id == head`.
  defp reject_stale_reviews(reviews, nil), do: reviews

  defp reject_stale_reviews(reviews, head_sha),
    do: Enum.filter(reviews, &(&1["commit_id"] == head_sha))

  defp decisive_verdict("APPROVED"), do: :approved
  defp decisive_verdict("REQUEST_CHANGES"), do: :changes_requested

  @doc """
  Feedback from a PR's in-force REQUEST_CHANGES reviews (Gitea `GET .../pulls/{index}/reviews`),
  to feed the producer's **rework**. Returns the LAST REQUEST_CHANGES review per reviewer
  with its `body` — the structured verdict recorded by the judge (`reason`/`details`/`chain`, via
  `StepRunConsumer.Verdict.judge_review_body`). Without this body, the `rework_brief` says "fix per the review"
  WITHOUT the review's content → the engineer guesses blindly (info famine, DOUBLE:
  twin of the judge's `outputs: {}`; without the body the eng returns `blocked_dep` rather than
  guessing). No commit-scoping here: we want the LAST feedback per reviewer (`List.last`), not
  a current decisive verdict (the rework runs BEFORE the next push, the REQUEST_CHANGES concerns
  the current head). Reviews without a body (generic verdict) are discarded (nothing actionable).

  ## Returns
    * `{:ok, [%{"login" => l, "body" => b}]}` — one entry per reviewer having a REQUEST_CHANGES with substance
    * `{:ok, []}` — no REQUEST_CHANGES with an actionable body
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec change_request_feedback(String.t(), integer(), Keyword.t()) ::
          {:ok, [%{optional(String.t()) => String.t()}]} | {:error, term()}
  def change_request_feedback(repo, index, opts \\ [])
      when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, reviews} when is_list(reviews) <-
           http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews") do
      {:ok, change_requests_by_reviewer(reviews)}
    else
      # F-C069 — 2xx non-list body → fail-loud (mirror of `paginate`), never `{:ok, []}` (an empty feedback
      # would silently give the eng a generic "fix per the review" without the review content).
      {:ok, non_list} ->
        {:error,
         {:unexpected_review_shape, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews",
          non_list}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Counts the REWORK rounds already triggered on a PR = number of non-dismissed `REQUEST_CHANGES`
  reviews (Gitea `GET .../pulls/{index}/reviews`). Each round (judge requests changes →
  the eng re-pushes → re-review) adds a REQUEST_CHANGES review → the counter is **forge-native** and
  MONOTONIC (the reviews persist), like `count_signed_step_runs` for the gate bounce. Serves the
  anti-churn brake of the PR-review path (`StepDispatcher.dispatch_rework`): beyond budget → arch escalation.

  No commit-scoping: we want the HISTORY of rounds (all commits), not the current verdict.

  `{:error, _}` on HTTP/config failure — the caller does NOT re-spawn blindly if the budget is not
  verifiable (an unbounded re-spawn could churn), symmetric to `count_signed_step_runs`.
  """
  @spec count_change_request_rounds(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_change_request_rounds(repo, index, opts \\ [])
      when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, reviews} when is_list(reviews) <-
           http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews") do
      count =
        reviews
        |> Enum.reject(&Map.get(&1, "dismissed", false))
        |> Enum.count(&(&1["state"] == "REQUEST_CHANGES"))

      {:ok, count}
    else
      # F-C069 — 2xx non-list body → fail-loud (mirror of `paginate`), never `{:ok, 0}` (an undercounted
      # rework budget → blind re-dispatch instead of arch escalation; the caller escalates on `{:error}`).
      {:ok, non_list} ->
        {:error,
         {:unexpected_review_shape, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews",
          non_list}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Judges RE-REQUESTED after having already judged (Gitea `GET .../issues/{index}/timeline`): logins whose
  NET review requests (`review_request` additions − removals) exceed the number of reviews rendered.
  This is the STRUCTURAL signal of a human gesture "re-request a judgment" (UI button) that neither the
  review-records (Gitea does NOT dismiss them on re-request — verified live) nor `requested_reviewers`
  (volatile) reveal. Without it, a re-request is INVISIBLE to the runtime: the judge is never
  re-dispatched, the merge attempts then fails in a loop on `not enough approvals` (wall observed 2026-07-07).

  **Counting, NOT temporal order** (forge lesson 2026-07-07): Gitea timestamps are at SECOND granularity →
  a review and its re-request within the same second make any `>`/`>=` ordering unreliable (missed or
  false-positive). Counting is IMMUNE to it. Prod sequence = `request_review`(1 addition) → review(1) →
  possible re-request(2nd addition). Net−reviews: 0 = up to date (not re-requested); >0 = an unanswered
  request → re-judgment due. CANCELLATION is absorbed by the SAME read: a removal
  (`removed_assignee: true`) decrements the net → the judge goes back to "up to date", the merge resumes. A single
  read covers the gesture AND its removal.

  Paginated timeline (fail-loud on a truncated page: a missed re-request = merge wedged silently). Downcased
  logins (consistent with `jury_reviewers`/`verdicts_by_reviewer`).

  ## Returns
    * `{:ok, ["qualifier", ...]}` — judges to re-dispatch (may be empty)
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec pr_rerequested_reviewers(String.t(), integer(), Keyword.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def pr_rerequested_reviewers(repo, index, opts \\ [])
      when is_binary(repo) and is_integer(index) do
    # `paginate` ALWAYS returns `{:ok, list}` (accumulated) or `{:error, _}` (including
    # `:unexpected_page_shape` on a non-list page — fail-loud, never an {:ok, non_list}): no
    # `{:ok, non_list}` clause to cover here (unlike single-page reads via `http_get`).
    with {:ok, config} <- resolve_config(opts),
         {:ok, events} <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{index}/timeline", "") do
      {:ok, rerequested_from_timeline(events)}
    end
  end

  # A judge is awaiting re-judgment iff its NET requests (additions − removals of `review_request`)
  # exceed its rendered reviews. Counting (immune to the second-granularity of timestamps), not
  # temporal order. Key = requested login (assignee), downcased.
  defp rerequested_from_timeline(events) do
    adds = tally(events, fn e -> requested_login(e, false) end)
    removals = tally(events, fn e -> requested_login(e, true) end)
    reviews = tally(events, &review_author/1)

    for {login, n_add} <- adds,
        # has ALREADY judged at least once (otherwise it's a 1st never-answered request = the standard jury,
        # NOT a re-judgment; this case doesn't reach the policy branch anyway, which assumes everything judged).
        n_rev = Map.get(reviews, login, 0),
        n_rev > 0,
        # NET requests > reviews → an unanswered review request remains (re-judgment due).
        n_add - Map.get(removals, login, 0) - n_rev > 0,
        do: login
  end

  # Counts, per login (↓), the events from which `key_fun` extracts a non-nil login (the others ignored).
  defp tally(events, key_fun) do
    Enum.reduce(events, %{}, fn e, acc ->
      case key_fun.(e) do
        login when is_binary(login) -> Map.update(acc, login, 1, &(&1 + 1))
        _ -> acc
      end
    end)
  end

  # Login requested by a `review_request` (the `assignee`, not the actor), filtered addition (want_removal false)
  # vs removal (true) via `removed_assignee`. Nil if the event is not a review_request of this type.
  defp requested_login(%{"type" => "review_request"} = e, want_removal) do
    if Map.get(e, "removed_assignee", false) == want_removal do
      e |> get_in(["assignee", "login"]) |> downcase_or_nil()
    end
  end

  defp requested_login(_e, _want_removal), do: nil

  defp review_author(%{"type" => "review"} = e),
    do: e |> get_in(["user", "login"]) |> downcase_or_nil()

  defp review_author(_e), do: nil

  defp downcase_or_nil(s) when is_binary(s) and s != "", do: String.downcase(s)
  defp downcase_or_nil(_), do: nil

  # Last REQUEST_CHANGES PER reviewer (login → body). Same ordering as `verdicts_by_reviewer` (Gitea
  # creation order → `List.last` = the in-force review), filtered to REQUEST_CHANGES with a non-empty body.
  defp change_requests_by_reviewer(reviews) do
    reviews
    |> Enum.reject(&Map.get(&1, "dismissed", false))
    |> Enum.filter(&(&1["state"] == "REQUEST_CHANGES"))
    |> Enum.group_by(&(get_in(&1, ["user", "login"]) |> to_string() |> String.downcase()))
    |> Enum.map(fn {login, revs} ->
      %{"login" => login, "body" => (List.last(revs)["body"] || "") |> to_string()}
    end)
    |> Enum.reject(&(String.trim(&1["body"]) == ""))
  end
end
