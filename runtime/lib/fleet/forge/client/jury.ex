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

  require Logger

  # Safe encoding of URL segments (path-traversal lock) — single authority UrlSafe.
  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1]

  # The read half of the role <-> forge-account frontier (the write half is `Client.request_review`).
  alias Fleet.Credentials.RoleIdentity

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
  def review_outcome(jury, verdicts) when is_list(jury) and is_map(verdicts),
    do: base_outcome(jury, verdicts)

  @doc """
  The same predicate, given what the judges MEASURED and the curve the card declares.

  `verdict = f(rapports, criticité)` — the origin model, and the four-arity is where it finally
  becomes true. The criticality reaches here as DATA (`policy`, resolved from the card that the
  project's declared level selected), never as a policy compiled into this module: same doctrine as
  `spec.ci` and `spec.jury` — the card governs, the engine stays agnostic.

  ## The one rule that keeps this safe

  **A card can only be STRICTER. It never repeals a judge's explicit refusal.** `:changes_requested`
  in, `:changes_requested` out, whatever the curve says. This is the same line the CI path was
  corrected onto (a card's `ci: ignore` cannot repeal the forge's floor): a judge that refuses is a
  floor, a card's tolerance is a ceiling, and a machine that promotes over an explicit human-shaped
  refusal is not a policy — it is an override.

  So the ONLY thing a policy can do is turn an `:approved` jury into `:changes_requested`, when a
  judge's own measurements exceed what this card tolerates. That case is real and is the whole
  point of the model: an approval carrying a `critical` finding is a judge that documented a defect
  and waved it through, and on a deliverable that can hurt someone, the card is what says no.

  Leniency is NOT expressible here, deliberately — a low-criticality card grants it by declaring no
  jury at all (`c0-poc`: `jury: []`), which is honest: nobody judged, so nobody was overruled.

  `policy` nil / no `block_at` / empty findings ⟹ IDENTICAL to `review_outcome/2`, byte-for-byte.
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
    # DEUX ÉTAGES, ET L'ORDRE EST LE MODÈLE : le PLANCHER d'abord (ce que le jury dit), le PLAFOND
    # de la carte ensuite, et il ne s'applique qu'à une approbation. Écrit comme un `cond` à cinq
    # branches, le même comportement laissait croire que la courbe est un juré de plus ; écrit
    # ainsi, on lit qu'elle ne peut QUE durcir — il n'existe aucun chemin par lequel elle promeut.
    #
    # C'est aussi ce qui rend `review_outcome/2` prouvablement incapable de rendre `:gray_zone`
    # (Dialyzer le vérifie) : sans politique il n'y a pas de zone grise, et cette impossibilité
    # est maintenant STRUCTURELLE au lieu d'être une propriété qu'il fallait croire sur parole.
    case base_outcome(jury, verdicts) do
      :approved ->
        if policy_blocks?(jury, findings, policy),
          do: arbitrated(verdicts, arbiter),
          else: :approved

      other ->
        other
    end
  end

  # Le prédicat NU : jury complet, un refus l'emporte. C'est l'agrégation booléenne d'origine, et
  # elle reste le socle sur lequel tout le reste se pose.
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

  # C3 — LA ZONE GRISE, ET ELLE A UNE DÉFINITION ÉTROITE : le jury a TOUT approuvé, et c'est la
  # courbe de la carte qui refuse. Rien d'autre n'est gris. Un refus de juge est net (plancher), une
  # PR propre est nette ; ici la machine s'apprête à renverser une approbation humaine-de-forme sur
  # la foi de mesures que ce même juge a écrites. C'est exactement le cas que le SP du gatekeeper
  # décrit — « tu es invoqué quand le runtime ne peut pas trancher seul ».
  #
  # L'arbitre n'est PAS un juré de plus : sa voix n'est lue QUE dans cette zone. Hors d'elle il ne
  # peut ni sauver un livrable qu'un juge refuse (le plancher est au-dessus de lui), ni bloquer une
  # PR que rien ne bloque (F-C061 : seuls les rôles du jury de la carte pèsent sur le verdict). Il
  # tranche une contradiction, il ne re-juge pas le travail.
  #
  # `:gray_zone` quand personne n'a encore arbitré — un état TERMINAL du prédicat, que le routage
  # transforme en convocation ; et sa lecture par la surface arch dit à un humain « le rail attend
  # un arbitrage », au lieu de lui montrer un « approuvé » qui ne se sellera jamais.
  defp arbitrated(_verdicts, nil), do: :gray_zone

  defp arbitrated(verdicts, arbiter) do
    case Map.get(verdicts, arbiter) do
      :approved -> :approved
      :changes_requested -> :changes_requested
      _ -> :gray_zone
    end
  end

  # The findings of a reviewer who is NOT on the jury are not consulted: a human passing by and
  # leaving a review does not get to raise the bar of a card they were never named in — the same
  # `Map.take(verdicts, jury)` discipline the clause above already applies to verdicts.
  defp policy_blocks?(jury, findings, %{"block_at" => block_at}) do
    findings
    |> Map.take(jury)
    |> Enum.any?(fn {_role, f} -> Fleet.FindingsWire.blocks?(f, block_at) end)
  end

  defp policy_blocks?(_jury, _findings, _policy), do: false

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
  `verdicts` — both are `:approved`. On the forge they never are: two `submitted_at` seconds apart
  versus a minute, and two incomparable bodies. `records` is what lets a reader tell them apart.
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
    # NO IMPLICIT UNSCOPED MODE. A `Keyword.get/2` here would send an ABSENT key and a `nil` VALUE
    # alike to "count every review ever placed on this PR" — and `nil` is exactly what the
    # production caller produces: `get_in(pr, ["head", "sha"])` on a forge answer whose PR object
    # omits `head.sha` (a lighter listing shape, a Gitea version, a partial response).
    #
    # WHAT THAT COSTS: a PR approved on commit A and then completed by commit B reads as still
    # approved, `review_outcome/2` yields `:approved`, the routing promotes, and `MergeAndPromote`
    # merges. Code no judge ever saw lands on the main branch, under a seal that attests the
    # opposite.
    #
    # The unscoped mode exists — some callers legitimately want every review — but it is ASKED FOR
    # (`head_sha: :unscoped`), never inherited from a missing key. That is the whole difference
    # between a default and a decision.
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

      # THE FORGE ANSWERS IN LOGINS, THE FLEET REASONS IN ROLES — translated here, at the frontier,
      # so nothing above ever holds an account name. Left untranslated, every fleet judge came back
      # as `fleet_qualifier` and got measured against a card that says `qualifier`: F-C061 filed the
      # jury itself as `foreign`, and the verdicts it carried were dropped. A login belonging to no
      # role stays verbatim — that is a HUMAN, and it must remain visibly foreign.
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
         # C2 — la courbe de la carte s'applique ICI AUSSI, et c'est la moitié qui compte de ce
         # geste. Cette sortie est celle que lit l'arch ; le gate calcule la sienne sur l'union
         # défensive du jury. Deux ENTRÉES, une RÈGLE — donc la politique doit entrer des deux
         # côtés ou d'aucun : nourrir le gate seul afficherait « approuvé » à un humain pendant que
         # le rail renvoie en rework, ce qui est exactement la seconde vérité que le @doc de
         # `review_outcome/2` existe pour interdire. Absente des opts ⟹ agrégation booléenne.
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

  # C2 — THE MACHINE VERDICT, READ OUT OF THE BODIES THIS FUNCTION ALREADY HOLDS. The judges'
  # `findings` rides its own review (`Fleet.FindingsWire`), so it arrives commit-scoped for
  # free: the same `reject_stale_reviews` that decides which VERDICT counts decides which findings
  # count, with no second rule to keep in sync. A judge that emitted nothing simply has no key --
  # absence is a fact the consumer reads, never an error invented here.
  #
  # Keyed by ROLE like `verdicts`, and for the same reason: no account name leaves this module.
  defp findings_by_role(decisive) do
    decisive
    |> Enum.reduce(%{}, fn {login, r}, acc ->
      case Fleet.FindingsWire.parse(r["body"]) do
        {:ok, findings} ->
          Map.put(acc, RoleIdentity.role_or_login(login), findings)

        # A block that is present and broken is NOT the same fact as no block -- and DROPPING it
        # spends the difference the moment it matters. Under a card that declares a floor, a
        # dropped payload is read downstream as "this judge measured nothing", so an unreadable
        # measurement REMOVES a block instead of raising one: a gray zone that owes an arbitration
        # gets sealed as `:approved`, with a log line as its only witness. Measured 2026-08-19 on
        # the two shipped cards that declare `block_at: critical`.
        #
        # So it is RECORDED, as a fact of its own kind. Not as a fabricated finding -- inventing a
        # `critical` nobody measured would put a defect in the record -- but as the honest one:
        # a measurement exists here and cannot be read. `FindingsWire.blocks?/2` answers `true` for
        # it whenever a floor is declared, because *unknown* must not be spent as *no*. A card with
        # no curve is untouched: no floor, no question, same behaviour as before.
        #
        # The binary verdict stays sovereign either way -- this is a ceiling, the judge is a floor.
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
        # Fleet-side name, like `verdicts` and `reviewers` above: an account name never leaves this
        # module. That is the invariant the whole fix rests on — one frontier, translated once — and
        # it is also what a reader wants, since the rework brief built from these records names the
        # judge to a pod whose world is made of roles.
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

  Read from the TIMELINE, because neither source above answers it: the review-records are not
  dismissed on re-request (verified live) and `requested_reviewers` only shows the current state. The paginated
  timeline is counted rather than timestamp-ordered because forge timestamps have second
  granularity. Removals cancel requests; truncated or malformed timelines fail.
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
