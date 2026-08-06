defmodule Fleet.Pilot.ForgeClient.Jury do
  @moduledoc """
  Reads the **jury state** of a PR (native Gitea reviews) — sub-domain of `Fleet.Pilot.ForgeClient`.
  Self-contained concern: it reads ONLY `GET .../pulls/{index}/reviews` and derives verdicts/jury/feedback
  from it; it calls no other forge op (zero coupling to the issues/PR core). `ForgeClient` forwards these
  functions (the module injected by the `:forge_client` seam stays `ForgeClient`; the implementation lives here).

  The domain subtlety — why this is NOT trivial — is the **commit-scoping** and the fact that
  Gitea's `requested_reviewers` is VOLATILE: the jury's source of truth is the list of review-records,
  not the requested field. Details in each `@doc`.
  """

  import Fleet.Pilot.ForgeClient.Transport, only: [resolve_config: 1, paginate: 3]

  # Safe encoding of URL segments (path-traversal lock) — single authority UrlSafe.
  import Fleet.Pilot.ForgeClient.UrlSafe, only: [encode_repo: 1]

  @doc """
  THE review-routing predicate — the SINGLE truth of "where does a jury stand", shared by the
  merge gate (`ReviewLifecycle.dispatch_by_verdicts`, fed the defensive UNION of jury sources)
  and the arch-facing status read (`pr_review_state`'s `outcome`, fed the stable jury). One rule,
  two inputs — factored so the status surface can NEVER drift from what the gate actually does.

    * `{:pending, [login↓]}` — at least one juror without a decisive verdict (input order kept)
    * `:no_jury`             — empty jury (zero-judge card or orphan PR — the CARD arbitrates, caller-side)
    * `:changes_requested`   — full jury, at least one REQUEST_CHANGES in force
    * `:approved`            — full jury, all APPROVED
  """
  @spec review_outcome([String.t()], %{optional(String.t()) => :approved | :changes_requested}) ::
          {:pending, [String.t()]} | :no_jury | :changes_requested | :approved
  def review_outcome(jury, verdicts) when is_list(jury) and is_map(verdicts) do
    pending = jury -- Map.keys(verdicts)

    cond do
      jury == [] ->
        :no_jury

      pending != [] ->
        {:pending, pending}

      Enum.any?(Map.values(Map.take(verdicts, jury)), &(&1 == :changes_requested)) ->
        :changes_requested

      true ->
        :approved
    end
  end

  @doc """
  Jury state of a PR in ONE fetch (`GET .../pulls/{index}/reviews`): `verdicts` (decisive per
  judge), `reviewers` (the jury SET) and `outcome` (cf. `review_outcome/2`).

  **Verdicts — why per-judge and not `requested_reviewers`**: Gitea 1.26 does NOT clear
  `requested_reviewers` when a judge has reviewed, and the DELETE is a no-op on an already-active
  reviewer → we CANNOT rely on it to know "who is left to judge". The SOURCE OF TRUTH = the list
  of reviews: a judge has a **decisive verdict** iff its last non-dismissed review is APPROVED or
  REQUEST_CHANGES (COMMENT/PENDING/REQUEST_REVIEW are NOT decisive), key = **downcased** login.

  **Commit-scoping (`:head_sha`)**: a verdict is only valid for the COMMIT it judged. Passing
  `head_sha: pr.head.sha` (prod path) → only reviews `commit_id == head_sha` count; a review
  on an earlier commit is STALE (the code no longer exists). Crucial for REQUEST_CHANGES: Gitea
  NEVER dismisses it on push (≠ stale approvals, dismissed by branch-protection) — without scoping, a
  stale REQUEST_CHANGES stays "active", its judge is never re-dispatched (it already has a verdict) and the
  PR would loop in infinite rework. Scoping makes it `pending` → re-judged on the current code.

  **The jury SET is NOT read from `pr.requested_reviewers`**: that field is VOLATILE (Gitea
  alters it unreliably — a judge can DISAPPEAR from it without having voted, which would merge on a
  half-jury). STABLE source = the review-records, which persist: a `REQUEST_REVIEW` =
  "this judge was requested"; an `APPROVED`/`REQUEST_CHANGES` = "it voted". The caller (`dispatch_review`)
  unions with `requested_reviewers` (defensive) and computes `pending = jury -- verdicts` → a
  never-voted judge stays `pending` (spawned), NEVER skipped.

  ## Returns
    * `{:ok, %{verdicts: %{login↓ => :approved | :changes_requested}, reviewers: [login↓],
      records: [%{"login", "verdict", "submitted_at", "body"}], outcome:
      review_outcome(reviewers, verdicts)}}` — `outcome` is computed HERE (pilot-side)
      and carried as DATA so a seam consumer (`get_issue_status`) renders the gate's own
      predicate without re-implementing it.
    * `{:error, term()}` — HTTP/transport/config

  `records` carries what `verdicts` cannot: the SUBSTANCE and the TIMING of each in-force verdict.
  The two are derived from ONE grouping (`decisive_by_reviewer/2`), because "which review is in
  force for this reviewer" is a single question and two implementations of it would drift — the
  routing would then act on one answer while the human read the other.

  Why it matters, and it is measured: a rubber stamp and a real review are indistinguishable in
  `verdicts` — both are `:approved`. On the forge they never were: two `submitted_at` seconds apart
  versus a minute, and two incomparable bodies. The architect's first blind spot was FALSE at the
  level of the data and TRUE at the level of its tools; this is the half that was missing.
  """
  @spec pr_review_state(String.t(), integer(), Keyword.t()) ::
          {:ok,
           %{
             verdicts: %{optional(String.t()) => :approved | :changes_requested},
             reviewers: [String.t()],
             records: [map()],
             outcome: {:pending, [String.t()]} | :no_jury | :changes_requested | :approved
           }}
          | {:error, term()}
  def pr_review_state(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    head_sha = Keyword.get(opts, :head_sha)

    with {:ok, config} <- resolve_config(opts),
         {:ok, reviews} <- paginated_reviews(config, repo, index) do
      decisive = decisive_by_reviewer(reviews, head_sha)
      verdicts = Map.new(decisive, fn {login, r} -> {login, decisive_verdict(r["state"])} end)
      reviewers = jury_reviewers(reviews)

      {:ok,
       %{
         verdicts: verdicts,
         reviewers: reviewers,
         records: to_records(decisive),
         outcome: review_outcome(reviewers, verdicts)
       }}
    end
  end

  # Reviews of a PR, PAGINATED: a jury verdict/feedback must see EVERY review — a decisive
  # APPROVED/REQUEST_CHANGES past the forge's default page would flip the outcome (merge on a jury
  # that actually rejected, or a rework brief missing the change-request). Maps paginate's non-list
  # fail-loud onto the review-specific `:unexpected_review_shape` (F-C069: NEVER `{:ok, []}` — an empty
  # jury here → `dispatch_by_verdicts([], %{})` → the MERGE branch, i.e. merge on a lost/empty jury).
  defp paginated_reviews(config, repo, index) do
    path = "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews"

    case paginate(config, path, "") do
      {:ok, reviews} ->
        {:ok, reviews}

      {:error, {:unexpected_page_shape, p, _page, body}} ->
        {:error, {:unexpected_review_shape, p, body}}

      {:error, _} = err ->
        err
    end
  end

  # The jury SET = every login with a "jury" review-record: requested (`REQUEST_REVIEW`) OR
  # having voted (`APPROVED`/`REQUEST_CHANGES`). Excludes `COMMENT`/`PENDING` (non-jury noise). STABLE source
  # (the records persist) vs volatile `requested_reviewers` → a judge dropped from the field without voting stays
  # in the jury → `pending` → spawned, never a merge on a half-jury.
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
  # The IN-FORCE review per reviewer, as the raw forge record. ONE definition of "in force", from
  # which both the routing verdict and the human-facing record derive: two implementations of the
  # same question drift, and the gate would then route on one answer while the architect reads the
  # other.
  defp decisive_by_reviewer(reviews, head_sha) do
    reviews
    |> Enum.reject(&Map.get(&1, "dismissed", false))
    |> Enum.filter(&(&1["state"] in ["APPROVED", "REQUEST_CHANGES"]))
    |> reject_stale_reviews(head_sha)
    |> Enum.group_by(&(get_in(&1, ["user", "login"]) |> to_string() |> String.downcase()))
    |> Map.new(fn {login, revs} -> {login, List.last(revs)} end)
  end

  # String keys and string values: these records cross the MCP seam and are rendered as JSON to an
  # agent. An atom verdict would serialize as a bare string anyway — saying so here keeps the shape
  # honest rather than leaving it to Jason.
  #
  # A body is kept VERBATIM, empty string included: "this judge approved and wrote nothing" is a
  # FACT about the review, and it is precisely the one worth seeing. Dropping empty bodies would
  # erase the rubber stamp this exists to make visible.
  defp to_records(decisive) do
    decisive
    |> Enum.map(fn {login, r} ->
      %{
        "login" => login,
        "verdict" => Atom.to_string(decisive_verdict(r["state"])),
        "submitted_at" => r["submitted_at"],
        "body" => r["body"] || ""
      }
    end)
    |> Enum.sort_by(& &1["submitted_at"])
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
         {:ok, reviews} <- paginated_reviews(config, repo, index) do
      {:ok, change_requests_by_reviewer(reviews)}
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
         {:ok, reviews} <- paginated_reviews(config, repo, index) do
      count =
        reviews
        |> Enum.reject(&Map.get(&1, "dismissed", false))
        |> Enum.count(&(&1["state"] == "REQUEST_CHANGES"))

      {:ok, count}
    end
  end

  @doc """
  Judges RE-REQUESTED after having already judged (Gitea `GET .../issues/{index}/timeline`): logins whose
  NET review requests (`review_request` additions − removals) exceed the number of reviews rendered.
  This is the STRUCTURAL signal of a human gesture "re-request a judgment" (UI button) that neither the
  review-records (Gitea does NOT dismiss them on re-request — verified live) nor `requested_reviewers`
  (volatile) reveal. Without it, a re-request is INVISIBLE to the runtime: the judge is never
  re-dispatched, and the merge attempt fails in a loop on `not enough approvals`.

  **Counting, NOT temporal order**: Gitea timestamps are at SECOND granularity →
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
    # `{:ok, non_list}` clause to cover here (all reads here paginate).
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
    # Keep BOTH decisive states, then take each reviewer's LAST review, THEN keep only those whose last
    # state is REQUEST_CHANGES — same ordering as `verdicts_by_reviewer`. Filtering REQUEST_CHANGES FIRST
    # (before the per-reviewer last) resurrected an objection a later APPROVED had already lifted: the
    # rework brief then cited feedback the judge no longer stands behind. No commit-scoping (cf. @doc: we
    # want the last feedback per reviewer, not the current-code verdict).
    |> Enum.filter(&(&1["state"] in ["APPROVED", "REQUEST_CHANGES"]))
    |> Enum.group_by(&(get_in(&1, ["user", "login"]) |> to_string() |> String.downcase()))
    |> Enum.map(fn {login, revs} -> {login, List.last(revs)} end)
    |> Enum.filter(fn {_login, last} -> last["state"] == "REQUEST_CHANGES" end)
    |> Enum.map(fn {login, last} ->
      %{"login" => login, "body" => (last["body"] || "") |> to_string()}
    end)
    |> Enum.reject(&(String.trim(&1["body"]) == ""))
  end
end
