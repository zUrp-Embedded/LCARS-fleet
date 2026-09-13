defmodule Fleet.Forge.Client.Jury do
  @moduledoc """
  Review verdicts, historical jury membership and timeline re-requests for Fleet.Forge.Client.
  Commit-scoped verdicts come from review records, not requested_reviewers, whose lifecycle
  differs across forge versions. Returned histories retain the paginator's limits and ordering.
  """

  import Fleet.Forge.Client.Transport, only: [resolve_config: 1, paginate: 3]

  require Logger

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1]

  # The read half of the role <-> forge-account frontier (the write half is `Client.request_review`).
  alias Fleet.Credentials.RoleIdentity

  @doc """
  Shared routing predicate for the gate and status read, which may supply different juries.
  Empty jury returns no_jury; missing keys return pending in input order before considering
  refusals. Once all keys exist, any changes_requested wins, otherwise approved.
  Inputs are not normalized or validated here: an unknown value under a juror key also
  counts as present and non-refusing. Consumers must supply the typed verdict vocabulary.
  """
  @spec review_outcome([String.t()], %{optional(String.t()) => :approved | :changes_requested}) ::
          {:pending, [String.t()]} | :no_jury | :changes_requested | :approved
  def review_outcome(jury, verdicts) when is_list(jury) and is_map(verdicts),
    do: base_outcome(jury, verdicts)

  @doc """
  Applies the caller's policy only after base_outcome is approved. A blocking finding from
  a named juror enters arbitration: no arbiter verdict yields gray_zone; an arbiter approval
  or refusal decides. The arbiter cannot override pending/no_jury or an explicit jury refusal.
  Only a string-keyed block_at policy is consulted, through FindingsWire.blocks?/2.
  No policy, no block_at or no blocking jury findings leaves the base outcome unchanged.
  """
  @spec review_outcome(
          [String.t()],
          %{optional(String.t()) => :approved | :changes_requested},
          %{optional(String.t()) => map()},
          map() | nil
        ) ::
          {:pending, [String.t()]} | :no_jury | :changes_requested | :approved | :gray_zone
  def review_outcome(jury, verdicts, findings, policy, arbiter \\ nil)
      when is_list(jury) and is_map(verdicts) and is_map(findings) do
    # Judge outcomes precede policy: arbitration cannot repeal a jury refusal.
    case base_outcome(jury, verdicts) do
      :approved ->
        if policy_blocks?(jury, findings, policy),
          do: arbitrated(verdicts, arbiter),
          else: :approved

      other ->
        other
    end
  end

  defp base_outcome(jury, verdicts) do
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

  # The arbiter matters only when the approved jury's findings conflict with policy.
  defp arbitrated(_verdicts, nil), do: :gray_zone

  defp arbitrated(verdicts, arbiter) do
    case Map.get(verdicts, arbiter) do
      :approved -> :approved
      :changes_requested -> :changes_requested
      _ -> :gray_zone
    end
  end

  # Outsiders' findings cannot raise the card's bar, just as their verdicts cannot veto its jury.
  defp policy_blocks?(jury, findings, %{"block_at" => block_at}) do
    findings
    |> Map.take(jury)
    |> Enum.any?(fn {_role, f} -> Fleet.FindingsWire.blocks?(f, block_at) end)
  end

  defp policy_blocks?(_jury, _findings, _policy), do: false

  @doc """
  Paginates native reviews and returns verdicts, reviewers, records, findings and outcome.
  Requires a nonempty binary head_sha or explicit :unscoped; nil/absent is refused before HTTP.
  Verdicts use the last non-dismissed APPROVED/REQUEST_CHANGES in server order per downcased login,
  filtered by exact commit_id when scoped. This avoids carrying stale approvals/refusals onto
  another commit; requested_reviewers and automatic dismissal do not establish that scope.

  Membership instead uses all REQUEST_REVIEW/APPROVED/REQUEST_CHANGES records, including stale
  and dismissed ones. Pilot combines sources defensively; this set is not the declared card jury.
  Known accounts are projected to roles, unknown logins retained; projection collisions are not
  detected. Records/findings share decisive selection. Bodies and timestamps help review the
  evidence, but do not prove review quality. outcome uses verdict_policy/verdict_arbiter options
  on this membership, which can differ from the gate's input jury.
  """
  @spec pr_review_state(String.t(), integer(), Keyword.t()) ::
          {:ok,
           %{
             verdicts: %{optional(String.t()) => :approved | :changes_requested},
             reviewers: [String.t()],
             records: [map()],
             findings: %{optional(String.t()) => map()},
             outcome:
               {:pending, [String.t()]} | :no_jury | :changes_requested | :approved | :gray_zone
           }}
          | {:error, term()}
  def pr_review_state(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    # A missing pr.head.sha must not silently widen the read to reviews of earlier commits.
    case Keyword.fetch(opts, :head_sha) do
      {:ok, :unscoped} -> do_review_state(repo, index, opts, nil)
      {:ok, sha} when is_binary(sha) and sha != "" -> do_review_state(repo, index, opts, sha)
      {:ok, other} -> {:error, {:head_sha_required, other}}
      :error -> {:error, {:head_sha_required, :absent}}
    end
  end

  defp do_review_state(repo, index, opts, head_sha) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, reviews} <- paginated_reviews(config, repo, index) do
      decisive = decisive_by_reviewer(reviews, head_sha)

      # Project known accounts to the card's role vocabulary; retain unknown logins as outsiders.
      verdicts =
        Map.new(decisive, fn {login, r} ->
          {RoleIdentity.role_or_login(login), decisive_verdict(r["state"])}
        end)

      reviewers = reviews |> jury_reviewers() |> Enum.map(&RoleIdentity.role_or_login/1)

      findings = findings_by_role(decisive)

      {:ok,
       %{
         verdicts: verdicts,
         reviewers: reviewers,
         records: to_records(decisive),
         findings: findings,
         # Status consumers need the same policy rule as the gate, even with different membership.
         outcome:
           review_outcome(
             reviewers,
             verdicts,
             findings,
             Keyword.get(opts, :verdict_policy),
             Keyword.get(opts, :verdict_arbiter)
           )
       }}
    end
  end

  # Findings share verdict selection/scope by travelling in the same review body.
  defp findings_by_role(decisive) do
    decisive
    |> Enum.reduce(%{}, fn {login, r}, acc ->
      case Fleet.FindingsWire.parse(r["body"]) do
        {:ok, findings} ->
          Map.put(acc, RoleIdentity.role_or_login(login), findings)

        # Preserve unreadability as its own sentinel: dropping it would bypass a declared
        # findings floor. FindingsWire blocks it under that policy without inventing a severity.
        {:error, :undecodable} ->
          Logger.warning(
            "Jury: #{login}'s review carries a findings block that does not decode — " <>
              "recorded as UNREADABLE (blocks under a declared floor), the binary verdict stands"
          )

          Map.put(acc, RoleIdentity.role_or_login(login), Fleet.FindingsWire.unreadable())

        :none ->
          acc
      end
    end)
  end

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

  # Last in server order, not max timestamp/id. Later COMMENT/PENDING records do not repeal
  # a decisive review. Unknown/missing login can form an empty-string group here.
  defp decisive_by_reviewer(reviews, head_sha) do
    reviews
    |> Enum.reject(&Map.get(&1, "dismissed", false))
    |> Enum.filter(&(&1["state"] in ["APPROVED", "REQUEST_CHANGES"]))
    |> reject_stale_reviews(head_sha)
    |> Enum.group_by(&(get_in(&1, ["user", "login"]) |> to_string() |> String.downcase()))
    |> Map.new(fn {login, revs} -> {login, List.last(revs)} end)
  end

  # String verdicts for MCP. Keep empty bodies visible; nil/false becomes "". Timestamps and
  # truthy bodies are not type-validated, and sorting here does not alter decisive selection.
  defp to_records(decisive) do
    decisive
    |> Enum.map(fn {login, r} ->
      %{
        "login" => RoleIdentity.role_or_login(login),
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

  Counts timeline additions minus removals minus reviews, requiring at least one review.
  Avoids second-resolution timestamp comparisons but does not establish event chronology.
  Names are downcased logins, not projected roles. Missing fields are often ignored; malformed
  nested shapes can raise. Pagination errors propagate, without a guarantee against silent
  server truncation. Review records/requested_reviewers alone do not retain this request history.
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
