defmodule Fleet.Forge.Client.Jury do
  @moduledoc """
  Reads the **jury state** of a PR (native Gitea reviews) — sub-domain of `Fleet.Forge.Client`.
  Self-contained concern: it reads ONLY `GET .../pulls/{index}/reviews` and derives verdicts/jury/feedback
  from it; it calls no other forge op (zero coupling to the issues/PR core). `ForgeClient` forwards these
  functions (the module injected by the `:forge_client` seam stays `ForgeClient`; the implementation lives here).

  The domain subtlety — why this is NOT trivial — is the **commit-scoping** and the fact that
  Gitea's `requested_reviewers` is VOLATILE: the jury's source of truth is the list of review-records,
  not the requested field. Details in each `@doc`.
  """

  import Fleet.Forge.Client.Transport, only: [resolve_config: 1, paginate: 3]

  # Safe encoding of URL segments (path-traversal lock) — single authority UrlSafe.
  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1]

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
      and carried as DATA so a seam consumer (`issue_status`) renders the gate's own
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

  # F-C069
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
  Returns the last substantive objection still in force for each reviewer.

  This historical feedback is not commit-scoped. A later approval supersedes an earlier objection;
  empty bodies are omitted.
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
  Counts all non-dismissed change requests as the forge-native, cross-commit rework budget.
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
  Returns downcased judges with an unanswered re-request after a prior review.

  review-records (Gitea does NOT dismiss them on re-request — verified live) nor `requested_reviewers`
  The paginated timeline is counted rather than timestamp-ordered because forge timestamps have
  second granularity. Removals cancel requests; truncated or malformed timelines fail.
  """
  @spec pr_rerequested_reviewers(String.t(), integer(), Keyword.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def pr_rerequested_reviewers(repo, index, opts \\ [])
      when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, events} <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{index}/timeline", "") do
      {:ok, rerequested_from_timeline(events)}
    end
  end

  defp rerequested_from_timeline(events) do
    adds = tally(events, fn e -> requested_login(e, false) end)
    removals = tally(events, fn e -> requested_login(e, true) end)
    reviews = tally(events, &review_author/1)

    for {login, n_add} <- adds,
        n_rev = Map.get(reviews, login, 0),
        n_rev > 0,
        n_add - Map.get(removals, login, 0) - n_rev > 0,
        do: login
  end

  defp tally(events, key_fun) do
    Enum.reduce(events, %{}, fn e, acc ->
      case key_fun.(e) do
        login when is_binary(login) -> Map.update(acc, login, 1, &(&1 + 1))
        _ -> acc
      end
    end)
  end

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

  defp change_requests_by_reviewer(reviews) do
    reviews
    |> Enum.reject(&Map.get(&1, "dismissed", false))
    # Select each reviewer's last decisive state before filtering objections.
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
