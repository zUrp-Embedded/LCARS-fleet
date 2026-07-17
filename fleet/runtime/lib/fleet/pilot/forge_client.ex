defmodule Fleet.Pilot.ForgeClient do
  @moduledoc """
  `fleet_pilot`'s Gitea REST API client — the DOMAIN layer of the forge-state-machine
  (the forge IS the state machine). Carries the ops on issues/PRs (idempotent read/write),
  PR jury state, repo onboarding, and the credential→wire adapter
  `as_role/2`. It is the module injected by the `:forge_client` seam (StepDispatcher/Poller).

  Two layers live BELOW it (re-exported here to preserve the historical contract):

    * `Fleet.Pilot.ForgeClient.Transport` — HTTP/config/encoding/pagination engine + system login.
      No knowledge of the forge protocol. `ForgeClient` `import`s it (`http_get`, `paginate`, …).
    * `Fleet.Pilot.ForgeProtocol` — PURE vocabulary of the wire-protocol (feature-branches,
      route/step_run/onboard markers, result blocks, `system_authored?`), build+parse co-located. Callers
      call it DIRECTLY. Only `parse_feature_branch/1` is re-exported here (`defdelegate`) because
      `fleet_mcp` reaches it via the `:forge_client` seam (avoids a compile-time dep on fleet_pilot).

  ⚠ CROSS CONTRACT (`fleet_mcp` seam): this module is the REAL (default) impl of the behaviour
  `Fleet.MCP.PodTools.Delegation.ForgeClient` (callbacks = `create_issue/4`, `add_label/4`,
  `get_issue/3`, `list_open_pulls/2`, `parse_feature_branch/1`, `pr_review_verdicts/3`). It CANNOT
  be adopted as a `@behaviour`: `Fleet.Pilot` does not depend on `Fleet.MCP` and the compile reference
  would be a Boundary violation (`Fleet.MCP` is absent from `Fleet.Pilot`'s `use Boundary` deps →
  compile error). Duck-typed impl — any evolution of
  these 6 signatures MUST be mirrored onto the behaviour's `@callback`s (and vice versa).

  ## Configuration

  Resolved at call time by `Transport.resolve_config/1` (see its moduledoc): `:base_url`, `:token`
  (or `:token_file`, default `~/.gitea_token`), `:req_options` passed to `Req`.

  ## Idempotence

  Write-ops are idempotent (skip if the target state is already reached). E.g. `add_label/4`:
  `GET issue labels` to short-circuit, else `POST issue/labels` by NAME (Gitea resolves repo+org
  server-side and dedups by name — no duplicate) with response VERIFICATION and repo-label self-heal;
  re-call on a label already present = `{:ok, :already_present}`, zero write round-trip.
  """

  require Logger

  alias Fleet.Pilot.ForgeClient.Jury
  alias Fleet.Pilot.ForgeClient.Repo
  alias Fleet.Pilot.ForgeProtocol

  # Plumbing pulled from Transport under the historical names → the domain call-sites stay
  # unchanged (`http_get(config, …)`, `paginate(…)`, `resolve_config(opts)`, …).
  import Fleet.Pilot.ForgeClient.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_patch: 3,
      http_delete: 2,
      paginate: 3,
      forge_bot_login: 2
    ]

  # Safe encoding of URL segments (path-traversal guard) — UrlSafe is the single authority.
  import Fleet.Pilot.ForgeClient.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  # ONLY re-export of the vocab: `parse_feature_branch/1`. `fleet_mcp` (pod_tools) calls it via the
  # `:forge_client` seam (runtime-resolved, defaulting to this module) so as NOT to create a compile-time dep on
  # fleet_pilot — the seam must therefore carry this function. The rest of the vocab (`feature_branch`,
  # `step_run_marker`, `result_block`, markers, `system_authored?`) is called directly on
  # `Fleet.Pilot.ForgeProtocol` (impl + tests live there); this module no longer re-exports it.
  defdelegate parse_feature_branch(head), to: ForgeProtocol

  @doc """
  Adds the label `label_name` to the issue `repo`/`issue_number` on the
  forge. Idempotent: if the label is already present, no write.

  ## Returns

    * `{:ok, :added}` — label freshly added
    * `{:ok, :already_present}` — label already on the issue (no-op)
    * `{:error, {:label_not_added, label_name}}` — the label could not be added
      (e.g. it does not exist in the repo — pre-provision it on the forge)
    * `{:error, {:http, status, body}}` — non-2xx HTTP response
    * `{:error, {:transport, reason}}` — network / DNS / ... failure
    * `{:error, {:config, reason}}` — missing config / unreadable token
  """
  @spec add_label(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :added | :already_present}
          | {:error, term()}
  def add_label(repo, issue_number, label_name, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) and is_binary(label_name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, current} <- get_issue_labels(config, repo, issue_number),
         current_names = Enum.map(current, & &1["name"]),
         false <- label_name in current_names && :already_present,
         :ok <- add_issue_label(config, repo, issue_number, label_name) do
      {:ok, :added}
    else
      :already_present -> {:ok, :already_present}
      {:error, _} = err -> err
    end
  end

  @doc """
  Lists the open issues of `repo` ASSIGNED TO ME (forge-side multi-user scoping). Building block of the
  repo-serialised dispatch lease (counts active pipelines, in-flight included). PAGINATED. Delegates to
  `list_scoped_issues` — issues AND PRs go through the SAME `/issues?type=…` endpoint (a single scoping code path).
  """
  @spec list_open_issues(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_issues(repo, opts \\ []) when is_binary(repo) do
    list_scoped_issues(repo, "issues", opts)
  end

  # A SINGLE lister on `/issues`, parameterised by `type` (issues|pulls) + assignee-scoped FORGE-SIDE.
  # Single source of the listing/scoping (state/type/assigned_by), paginated. The forge filters
  # (`assigned_by` — Gitea 1.26.1 works on /issues for both types) → the poller sees
  # ONLY its own (the lease becomes per-human, consistent with N-fleets-per-human). The scoping lives HERE, in a
  # single place — decide/dispatch_review no longer have to re-check ownership.
  defp list_scoped_issues(repo, type, opts) when type in ["issues", "pulls"] do
    with {:ok, config} <- resolve_config(opts) do
      paginate(
        config,
        "/repos/#{encode_repo(repo)}/issues",
        "state=open&type=#{type}" <> assigned_by_qs(opts)
      )
    end
  end

  # Query suffix `&assigned_by=<login>` if `opts[:assigned_by]` is set, otherwise "". Pure/testable.
  @doc false
  def assigned_by_qs(opts) do
    case Keyword.get(opts, :assigned_by) do
      login when is_binary(login) and login != "" -> "&assigned_by=" <> URI.encode_www_form(login)
      _ -> ""
    end
  end

  @doc """
  Reads an issue by number (Gitea `GET /repos/{repo}/issues/{n}`). Read-only: `state`
  (open/closed), labels, assignees… Used by the MCP tool `get_issue_status` (the arch FOLLOWS a
  delegated issue — e.g. validating the delivery before chaining on). `{:error, {:http, 404, _}}` if absent.
  """
  @spec get_issue(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def get_issue(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      http_get(config, "/repos/#{encode_repo(repo)}/issues/#{number}")
    end
  end

  @doc """
  Comments of an issue (Gitea `GET /repos/{repo}/issues/{n}/comments`), oldest-first. Read-only.
  Used by the MCP `list_escalations` tool: the escalation VERDICT of a worker's `escalate_user`
  is posted as a comment (by `StepRunCompleter`), and the arch must READ it to decide. Single page
  (an escalated issue carries a handful of comments — the verdict is the most recent); `{:error, _}`
  on HTTP/transport. NOT a mutation despite living below the write-ops banner — placed by the arch's read path.
  """
  @spec list_comments(String.t(), integer(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      http_get(config, "/repos/#{encode_repo(repo)}/issues/#{number}/comments")
    end
  end

  # ============================================================
  # Write-ops — mechanical primitives of step-run end (the forge IS the state machine).
  # All idempotent (skip if the target state is already reached).
  # ============================================================

  @doc """
  Reassigns the issue to `login` (strict 1-assignee, workflow_map invariant). PATCH `assignees: [login]`
  replaces the list. Idempotent: `{:ok, :already}` if `login` is already the only assignee.
  """
  @spec set_assignee(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :set | :already} | {:error, term()}
  def set_assignee(repo, issue_number, login, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) and is_binary(login) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, issue} <- http_get(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}") do
      current = Enum.map(Map.get(issue, "assignees") || [], & &1["login"])

      if current == [login] do
        {:ok, :already}
      else
        case http_patch(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}", %{
               assignees: [login]
             }) do
          {:ok, _} -> {:ok, :set}
          {:error, _} = err -> err
        end
      end
    end
  end

  # The workflow_map POSITION (= the state-machine state) lives in the SCOPED label `stage/*` (Gitea
  # native mutex, single source visible to human+machine), set by `post_route` / read by `get_route`.
  # No more `[lcars-route:...]` comment (noise). The FLAT locks (`lcars-in-flight`) stay
  # non-scoped via `add_label`/`remove_label`.

  @doc """
  Posts a comment. If `:dedup_signature` is provided and an existing **system**
  comment already contains it, no-op (`{:ok, :already}`) — the signature `[step_run:<role>:<sha>]` makes the
  replay idempotent. The dedup trusts ONLY the bot's comments: otherwise a
  forge user posting the signature ahead of time would suppress the system comment (→ `count_signed_step_runs`
  would undercount). Unresolvable bot → trust NOBODY (fail-closed): the marker is (re-)posted, never suppressed.
  """
  @spec post_comment(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :posted | :already} | {:error, term()}
  def post_comment(repo, issue_number, body, opts \\ [])
      when is_binary(body) do
    sig = Keyword.get(opts, :dedup_signature)

    with {:ok, config} <- resolve_config(opts) do
      if sig && comment_signed?(config, repo, issue_number, sig, opts) do
        {:ok, :already}
      else
        case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", %{
               body: body
             }) do
          {:ok, _} -> {:ok, :posted}
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc """
  Removes the label `label_name` (release of the `lcars-in-flight` lock at step-run end).
  Idempotent: `{:ok, :already_absent}` if the label is not present.
  """
  @spec remove_label(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :removed | :already_absent} | {:error, term()}
  def remove_label(repo, issue_number, label_name, opts \\ [])
      when is_binary(label_name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, current} <- get_issue_labels(config, repo, issue_number) do
      # The `id` comes from the labels ATTACHED to the issue (`current`), not a repo index (which misses
      # org-labels): an attached org-label appears there with its id → DELETE works for repo AND org.
      case Enum.find(current, &(&1["name"] == label_name)) do
        nil ->
          {:ok, :already_absent}

        %{"id" => id} ->
          case http_delete(
                 config,
                 "/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels/#{id}"
               ) do
            {:ok, _} -> {:ok, :removed}
            {:error, _} = err -> err
          end
      end
    end
  end

  # ============================================================
  # Gitea native time-tracking (stopwatch) — GLOBAL MECHANICS, agnostic of role/agent.
  # `number` = the object locked by `lcars-in-flight` (issue OR PR — Gitea unifies both under
  # `issues/{n}/stopwatch`, a PR IS an issue on the model side). Wired to the 3 SAME convergence points
  # as the lock itself (spawn_step SETS it, unlock/reconciliation LIFT it): start_stopwatch/2 when
  # `lcars-in-flight` is set, stop_stopwatch/2 when it is lifted — A SINGLE mechanism, zero per-role
  # branch (consultant/engineer/qualifier/reviewer/gatekeeper all go through the same 2 points).
  # ============================================================

  @doc """
  Starts the Gitea native stopwatch on `number` (issue or PR). Idempotent: 409
  ("already active", a rebrief on a live pod re-sets the same lock) → `:ok`, not an error.
  Like `stop_stopwatch/3`: the stopwatch is cosmetic time-tracking, never a pipeline-correctness
  invariant — any other error is returned, and it is the caller's business not to block on it.
  """
  @spec start_stopwatch(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def start_stopwatch(repo, number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{number}/stopwatch/start", %{}) do
        {:ok, _} -> :ok
        {:error, {:http, 409, _}} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Stops the Gitea native stopwatch on `number` (records the elapsed duration). Idempotent:
  409 ("no active stopwatch") → `:ok`, never a blocking error (the stopwatch is cosmetic,
  not a pipeline-correctness invariant).
  """
  @spec stop_stopwatch(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def stop_stopwatch(repo, number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{number}/stopwatch/stop", %{}) do
        {:ok, _} -> :ok
        {:error, {:http, 409, _}} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Closes the issue (chain terminal). PATCH `state: closed`. Idempotent on the Gitea side.
  """
  @spec close_issue(String.t(), integer(), Keyword.t()) :: {:ok, :closed} | {:error, term()}
  def close_issue(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_patch(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}", %{
             state: "closed"
           }) do
      {:ok, :closed}
    end
  end

  # ============================================================
  # Repo / onboarding — DELEGATED to `Fleet.Pilot.ForgeClient.Repo`.
  # Provisioning (create_repo/protect_branch) + discovery by org-membership
  # (list_org_repos, WS3). The provisioning ops are called DIRECTLY on `ForgeClient.Repo` (by
  # `ProjectOnboard`); only the SEAM-FACED ops below are forwarded (the module injected by the
  # seam stays THIS module). Doc + logic live in `Repo`.
  # ============================================================

  @doc "Org repos (WS3 discovery, org-membership = admission). See `ForgeClient.Repo.list_org_repos/2`."
  def list_org_repos(org, opts \\ []), do: Repo.list_org_repos(org, opts)

  @doc "Numeric forge id of the repo. See `Fleet.Pilot.ForgeClient.Repo.repo_id/2`."
  def repo_id(repo, opts \\ []), do: Repo.repo_id(repo, opts)

  @doc """
  Creates an issue on `repo`. `opts[:assignees]` = logins, `opts[:labels]` = integer IDs
  (the routing label `type:*` is rather set via `add_label/4` afterwards, name→id resolution).
  Returns the issue number.

  ## Returns
    * `{:ok, issue_number}` — issue created
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec create_issue(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def create_issue(repo, title, body, opts \\ [])
      when is_binary(repo) and is_binary(title) and is_binary(body) do
    with {:ok, config} <- resolve_config(opts) do
      attrs = %{
        title: title,
        body: body,
        assignees: Keyword.get(opts, :assignees, []),
        labels: Keyword.get(opts, :labels, [])
      }

      case http_post(config, "/repos/#{encode_repo(repo)}/issues", attrs) do
        {:ok, %{"number" => number}} -> {:ok, number}
        {:error, _} = err -> err
      end
    end
  end

  # ============================================================
  # Pull requests (git-native) — the PR is the surface of the
  # REVIEW+PROMOTE phase: durable home of the gate verdicts (Gitea native review) and
  # single funnel toward `main`. Barrier: the SYSTEM opens/reviews/merges, the pod
  # never has the token. IDEMPOTENT primitives (replayable without breaking).
  # ============================================================

  @doc """
  Opens a pull request `head` → `base` on `repo` (Gitea `POST /repos/{repo}/pulls`).
  IDEMPOTENT: if an open PR already exists for this `head`, returns its number (the
  Gitea 409 is not an error). `opts[:body]` = body. (No `Closes #N` auto-close: it was removed
  2026-07-07 — the issue is closed EXPLICITLY by `GatekeeperSeal.seal_and_merge` after the seal.)

  ## Returns
    * `{:ok, number}` — PR opened (or already existing)
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec open_pr(String.t(), String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def open_pr(repo, head, base, title, opts \\ [])
      when is_binary(repo) and is_binary(head) and is_binary(base) and is_binary(title) do
    with {:ok, config} <- resolve_config(opts) do
      attrs = %{head: head, base: base, title: title, body: Keyword.get(opts, :body, "")}

      case http_post(config, "/repos/#{encode_repo(repo)}/pulls", attrs) do
        {:ok, %{"number" => number}} -> {:ok, number}
        # PR already open for this head (Gitea 409) → idempotence: we find it again.
        {:error, {:http, 409, _}} -> get_pr_for_branch(repo, head, base, opts)
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Finds the OPEN PR `head` → `base` on `repo` (Gitea `GET /repos/{repo}/pulls`, filtered
  client-side by `head.ref`/`base.ref`). Idempotence building block of `open_pr/5`.

  ## Returns
    * `{:ok, number}` — PR found
    * `{:error, :pr_not_found}` — no open PR head→base
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec get_pr_for_branch(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def get_pr_for_branch(repo, head, base, opts \\ [])
      when is_binary(repo) and is_binary(head) and is_binary(base) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/repos/#{encode_repo(repo)}/pulls?state=open&limit=50") do
        {:ok, pulls} when is_list(pulls) ->
          case Enum.find(pulls, &pr_matches_head?(&1, head, base)) do
            %{"number" => number} -> {:ok, number}
            _ -> {:error, :pr_not_found}
          end

        {:ok, _} ->
          {:error, :pr_not_found}

        {:error, _} = err ->
          err
      end
    end
  end

  defp pr_matches_head?(pr, head, base) do
    get_in(pr, ["head", "ref"]) == head and get_in(pr, ["base", "ref"]) == base
  end

  @doc """
  Requests review from the `reviewers` (logins) on the PR `index` (Gitea
  `POST /repos/{repo}/pulls/{index}/requested_reviewers`). This is the TRIGGER
  mechanics of the judge phase — replaces `set_assignee` on the PR side (the poller spawns the
  judge on the review-request).
  """
  @spec request_review(String.t(), integer(), [String.t()], Keyword.t()) ::
          :ok | {:error, term()}
  def request_review(repo, index, reviewers, opts \\ [])
      when is_binary(repo) and is_integer(index) and is_list(reviewers) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/requested_reviewers", %{
             reviewers: reviewers
           }) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Posts a native review on the PR `index` (Gitea `POST /repos/{repo}/pulls/{index}/reviews`).
  `event` ∈ `:approve | :request_changes | :comment` → this is the durable HOME of the gate
  verdict (traceable native review, vs the old home-grown JSON-comment). `body` = the human-readable verdict.
  """
  @spec post_review(
          String.t(),
          integer(),
          :approve | :request_changes | :comment,
          String.t(),
          Keyword.t()
        ) :: :ok | {:error, term()}
  def post_review(repo, index, event, body, opts \\ [])
      when is_binary(repo) and is_integer(index) and is_binary(body) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, gitea_event} <- review_event(event) do
      case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews", %{
             event: gitea_event,
             body: body
           }) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp review_event(:approve), do: {:ok, "APPROVED"}
  defp review_event(:request_changes), do: {:ok, "REQUEST_CHANGES"}
  defp review_event(:comment), do: {:ok, "COMMENT"}
  defp review_event(other), do: {:error, {:invalid_review_event, other}}

  @doc """
  Merges (PROMOTES) the PR `index` via **`rebase`** (Gitea `POST /repos/{repo}/pulls/{index}/merge`,
  `Do: rebase` by default): replays the PR's commits onto the current `main` then fast-forwards →
  stays **LINEAR** (no merge commit, append-only doctrine preserved) AND handles a `main` that has
  advanced under the PR (PARALLEL MULTI-ISSUE: 2 disjoint issues → 2 PRs off the same `main` → the 1st
  merge advances `main`, the 2nd is no longer FF-able but stays mergeable → `rebase` gets it through; `fast-forward-only`
  would wedge it forever).

  **NO FF→rebase cascade**: a 1st attempt that fails throws the PR back into "checking" state
  (Gitea recomputes mergeability ASYNCHRONOUSLY), and the 2nd back-to-back attempt hits that
  window → `405 "Please try again later"` (double-call = double-405; `rebase` alone
  on a stable PR = 200). So A SINGLE call, and the `405 try-again-later` is treated as a
  **TRANSIENT** (bounded retry `@merge_checking_retries` × `merge_retry_delay_ms`, default 800ms — the
  mergeability stabilises in ~1 computation). Any other failure (real conflict, no approvals under
  branch-protection) propagates as-is (fail-loud). `opts[:method]` forces a style (e.g. tests).
  """
  @merge_checking_retries 3
  @spec merge_pr(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def merge_pr(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts) do
      method = Keyword.get(opts, :method, "rebase")
      delay = Keyword.get(opts, :merge_retry_delay_ms, 800)
      do_merge(config, repo, index, method, delay, @merge_checking_retries)
    end
  end

  # ONE `Do: method` call; bounded retry ONLY on the "try again later" transient (mergeability
  # being computed on the Gitea side). Any other error = definitive → propagates (fail-loud).
  defp do_merge(config, repo, index, method, delay, attempts_left) do
    case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/merge", %{
           "Do" => method
         }) do
      {:ok, _} ->
        delete_head_branch_spaced(config, repo, index)
        :ok

      {:error, {:http, 405, body}} = err ->
        if attempts_left > 1 and merge_checking?(body) do
          Logger.info(
            "ForgeClient: merge_pr ##{index} mergeability in progress ('try again later') → " <>
              "retry in #{delay}ms (#{attempts_left - 1} remaining)"
          )

          Process.sleep(delay)
          do_merge(config, repo, index, method, delay, attempts_left - 1)
        else
          err
        end

      {:error, _} = err ->
        err
    end
  end

  # Gitea transient: a PR's mergeability is recomputed asynchronously (after creation / push / an
  # advanced `main`) → any merge attempt during that computation returns 405 "Please try again later".
  defp merge_checking?(body) when is_map(body),
    do: body |> Map.get("message", "") |> String.downcase() |> String.contains?("try again later")

  defp merge_checking?(_), do: false

  # Deletes the merged feature-branch `lcars/issue-N-role` (hygiene: no pile-up of dead branches)
  # as a SEPARATE call AFTER a `WriteSpacing.gap` — `delete_branch_after_merge` bundled both into one
  # Gitea transaction, whose two feed events ("pushed on main" + "branch deleted") tied in the same
  # second and displayed in an arbitrary order. The merge stays the authority: any failure here is a
  # WARNING (a surviving dead branch is cosmetic), never a merge error.
  defp delete_head_branch_spaced(config, repo, index) do
    with {:ok, pr} <- http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}"),
         head_ref when is_binary(head_ref) and head_ref != "" <- get_in(pr, ["head", "ref"]) do
      Fleet.Workflow.WriteSpacing.gap()

      case http_delete(config, "/repos/#{encode_repo(repo)}/branches/#{encode_seg(head_ref)}") do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "ForgeClient: post-merge delete of #{head_ref} failed (#{inspect(reason)}) — dead branch survives"
          )
      end
    else
      other ->
        Logger.warning(
          "ForgeClient: post-merge head.ref unreadable for #{repo}##{index} (#{inspect(other)}) — branch not deleted"
        )
    end

    :ok
  end

  @doc """
  Lists the OPEN PRs of `repo` ASSIGNED TO ME (forge-side multi-user scoping), FULL PR
  shape: `number`, `head.ref` (feature-branch `lcars/issue-N-role`), `head.sha`, `requested_reviewers`,
  `labels`. PAGINATED. Building block of the PR-driven judge dispatch.

  Hybrid (Gitea 1.26.1): `/pulls` does NOT have `assigned_by`, but `/issues?type=pulls&assigned_by`
  filters the assignee (returning an ISSUE shape, without head/requested_reviewers). So we FILTER via
  `list_scoped_issues(type: pulls)` — SAME scoping/pagination code as the issues — then fetch the
  full PR shape via `get_pull/3`, 1 per number. The scoping stays 100% forge-side, like the issues.
  """
  @spec list_open_pulls(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_pulls(repo, opts \\ []) when is_binary(repo) do
    with {:ok, pr_issues} <- list_scoped_issues(repo, "pulls", opts) do
      pr_issues |> Enum.map(& &1["number"]) |> fetch_pulls(repo, opts)
    end
  end

  # Fetches the full PR shape (head/head.sha/requested_reviewers) for each filtered number. Fail-fast:
  # an error on one PR halts everything (we don't dispatch on a partial view, like pagination).
  defp fetch_pulls(numbers, repo, opts) do
    numbers
    |> Enum.reduce_while({:ok, []}, fn n, {:ok, acc} ->
      case get_pull(repo, n, opts) do
        {:ok, pr} -> {:cont, {:ok, [pr | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, prs} -> {:ok, Enum.reverse(prs)}
      err -> err
    end
  end

  @doc "GET a single PR → full shape (head/head.sha/requested_reviewers). Building block of list_open_pulls."
  @spec get_pull(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def get_pull(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts),
         do: http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{number}")
  end

  # ============================================================
  # PR Jury — DELEGATED to `Fleet.Pilot.ForgeClient.Jury`.
  # Autonomous concern (reading reviews, zero coupling to the core). The module injected by the
  # `:forge_client` seam stays THIS module → we FORWARD (explicit wrappers: `defdelegate` doesn't handle
  # default args). Doc + logic (commit-scoping, volatile jury) live in `Jury`.
  # ============================================================

  @doc "Decisive per-judge verdicts of a PR. See `Fleet.Pilot.ForgeClient.Jury.pr_review_verdicts/3`."
  def pr_review_verdicts(repo, index, opts \\ []), do: Jury.pr_review_verdicts(repo, index, opts)

  @doc "Jury state (verdicts + jury SET) of a PR. See `Fleet.Pilot.ForgeClient.Jury.pr_review_state/3`."
  def pr_review_state(repo, index, opts \\ []), do: Jury.pr_review_state(repo, index, opts)

  @doc "Feedback of the REQUEST_CHANGES in force. See `Fleet.Pilot.ForgeClient.Jury.change_request_feedback/3`."
  def change_request_feedback(repo, index, opts \\ []),
    do: Jury.change_request_feedback(repo, index, opts)

  @doc "Counts the rework rounds. See `Fleet.Pilot.ForgeClient.Jury.count_change_request_rounds/3`."
  def count_change_request_rounds(repo, index, opts \\ []),
    do: Jury.count_change_request_rounds(repo, index, opts)

  @doc "Judges re-requested after judgment (timeline). See `Fleet.Pilot.ForgeClient.Jury.pr_rerequested_reviewers/3`."
  def pr_rerequested_reviewers(repo, index, opts \\ []),
    do: Jury.pr_rerequested_reviewers(repo, index, opts)

  # put_file / get_file → `Fleet.Pilot.ForgeClient.Files` (autonomous concern, called directly, not via
  # the seam — `IncidentRegistry` injects them as `:get_file_fun`/`:put_file_fun`). No forwarder here.

  defp comment_signed?(config, repo, issue_number, sig, opts) do
    # Paginated — a signed system comment beyond 50 must not escape the dedup (otherwise
    # double-post on replay). A page of unexpected shape yields `{:error, …}` (and not a
    # truncated `{:ok, acc}`) → falls into the `_ -> false` (no signature found = we post, fail-safe
    # dedup: at worst a double-post on replay, never a silent suppression of a marker).
    case paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      {:ok, comments} when is_list(comments) ->
        # The dedup guards a system WRITE → trusts only the bot's comments. Otherwise a forge user posts the
        # signature ahead of time → the system comment is skipped → `count_signed_step_runs` undercounts
        # (over-permissive anti-runaway budget). Unresolvable bot → trust NOBODY (`[]`), FAIL-CLOSED: a forged
        # signature is NOT believed "already posted" → the system marker IS (re-)posted (at worst a double-post
        # on replay — over-count-safe for the budget — NEVER a silent suppression). Same fail-safe stance as
        # the paginate-error branch below.
        # NON load-bearing marker (e.g. `[merge:pr-N]`, posted by the gatekeeper ROLE
        # account and not the system bot) → AUTHOR-AGNOSTIC dedup. The bot-only filter only
        # protects the COUNTED markers (`[step_run:role:sha]` → count_signed_step_runs): a gatekeeper
        # seal comment would otherwise escape the bot-only dedup (double-post on replay/retry).
        trusted =
          if Keyword.get(opts, :dedup_any_author, false) do
            comments
          else
            case forge_bot_login(config, opts) do
              {:ok, bot} -> Enum.filter(comments, &ForgeProtocol.system_authored?(&1, bot))
              # Unresolvable bot → trust NOBODY (fail-closed), NOT everybody: a forged signature must not
              # be believed "already posted" (which would SUPPRESS the system marker → undercount).
              {:error, _} -> []
            end
          end

        Enum.any?(trusted, fn c -> String.contains?(c["body"] || "", sig) end)

      _ ->
        false
    end
  end

  # ============================================================
  # workflow_map position — 2 SCOPED labels on the issue (the forge IS the state machine).
  # Replaces the old `[lcars-route:<map>:<step>]` comment (noise in the human thread):
  #   `stage/<step>`: the CURRENT step, mobile (Gitea native mutex: setting a step removes the previous one).
  #   `wfmap/<map>` : WHICH map this issue follows, set once (mutex: a single map per issue).
  # Both VISIBLE (human glance), read directly (no comment scan), unfalsifiable
  # via the WS1 write lock (roles at issues:read): unrepresentability > filtering-at-read.
  # The map lives PER-ISSUE (data) — NOT a coded global default: two issues can follow two maps
  # (multi-map, cf. gkchain/poc-mini tests). No `default` here: a map default has only ONE
  # legitimate place, the onboard of a routeless issue (`StepDispatcher.ensure_workflow_map_or_onboard`).
  # ============================================================

  # Scoped prefixes read from the SINGLE SOURCE of the vocab (`Fleet.Labels`) — no re-declaration
  # of the literal (a rename there propagates here at compile time).
  @stage_prefix Fleet.Labels.stage_prefix()
  @wfmap_prefix Fleet.Labels.wfmap_prefix()

  @doc """
  Sets the position = `wfmap/<pipeline>` (which map, idempotent) + `stage/<step>` (via `set_stage`, mutex).
  `{:ok, :posted}` if the step moved, `{:ok, :already}` if already at that step, `{:error, _}` otherwise.
  """
  @spec post_route(String.t(), integer(), String.t(), String.t(), Keyword.t()) ::
          {:ok, :posted | :already} | {:error, term()}
  def post_route(repo, issue_number, pipeline, step, opts \\ [])
      when is_binary(pipeline) and is_binary(step) do
    with {:ok, _} <- add_label(repo, issue_number, wfmap_label(pipeline), opts) do
      set_stage(repo, issue_number, step, opts)
    end
  end

  @doc """
  Sets ONLY the current step `stage/<stage>` (mutex: removes the old `stage/*`), without touching
  `wfmap/*`. Serves the post-map PR LIFECYCLE (`review` at the opening of the deliverable PR, `merged` at merge):
  the step is no longer a navigable workflow_map position but stays visible for the human. The poller does
  not re-read `get_route` on these issues (PR-backed → skip lease.ex:209; merged → closed) → `stage/*` there is
  purely human. `{:ok, :posted | :already}` | `{:error, _}`.
  """
  @spec set_stage(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :posted | :already} | {:error, term()}
  def set_stage(repo, issue_number, stage, opts \\ []) when is_binary(stage) do
    case add_label(repo, issue_number, stage_label(stage), opts) do
      {:ok, :added} -> {:ok, :posted}
      {:ok, :already_present} -> {:ok, :already}
      {:error, _} = err -> err
    end
  end

  @doc """
  Reads the position = `{:ok, {map, step}}` from the issue's `wfmap/<map>` + `stage/<step>` labels.
  `:none` if one is missing (routeless issue, or half-state → re-onboarded by the caller). `{:error, _}` on
  HTTP/config failure. The map comes from the DATA (label `wfmap/*`), never from a coded default — no
  silent invention of a map (canon: ambiguity rejected, no hidden business fallback). The
  TRUST comes from the WS1 write lock (only `lcars-system` sets the labels): unrepresentability >
  filtering-at-read. Threat model: a compromised role setting a fake `stage/*` = nuke&redeploy.
  """
  @spec get_route(String.t(), integer(), Keyword.t()) ::
          {:ok, {String.t(), String.t()}} | :none | {:error, term()}
  def get_route(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, labels} <- get_issue_labels(config, repo, issue_number) do
      case {current_wfmap(labels), current_stage(labels)} do
        {map, step} when is_binary(map) and is_binary(step) -> {:ok, {map, step}}
        _ -> :none
      end
    end
  end

  # Position label builders (single-source of the literals with `@stage_prefix`/`@wfmap_prefix`).
  defp stage_label(step) when is_binary(step), do: @stage_prefix <> step
  defp wfmap_label(map) when is_binary(map), do: @wfmap_prefix <> map

  # Current step = value of the `stage/<step>` label (at most one: mutex). Map = value of the `wfmap/<map>`.
  defp current_stage(labels), do: label_value(labels, @stage_prefix)
  defp current_wfmap(labels), do: label_value(labels, @wfmap_prefix)

  # Value (suffix) of the issue's 1st scoped label `<prefix><value>`, nil if none. Generic across both scopes.
  defp label_value(labels, prefix) when is_list(labels) do
    Enum.find_value(labels, fn label ->
      name = label["name"]

      if is_binary(name) and String.starts_with?(name, prefix),
        do: String.replace_prefix(name, prefix, "")
    end)
  end

  @doc """
  Counts the comments carrying a signed step_run marker `[step_run:<role>:<sha>]`
  (posted by `StepRunCompleter` at each step-run end). Serves as the **forge-native** counter
  for the anti-runaway bound of the gate bounce: how many step_runs have already been
  played on the issue. Monotone (comments are not removed), idempotent to read.

  `{:error, _}` on HTTP/config failure — the caller does NOT bounce blindly if the
  budget is not verifiable (an unverifiable bounce could loop).

  PAGINATED: even though the rework budget (`nb_steps * (max_rounds+1)`) generally
  stays under 50, the counter is the source-of-truth of the anti-runaway bound — a signed step_run
  lost beyond 50 would undercount the budget (over-permissive). So we read ALL the pages.
  """
  @spec count_signed_step_runs(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_signed_step_runs(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      # Count ONLY the step_runs signed by the SYSTEM — otherwise a forge user forges
      # `[step_run:role:sha]` to inflate the counter and TRIP the anti-runaway budget (rework DoS).
      # Unresolvable bot → {:error} (via the with): the caller does NOT bounce on an unverifiable budget.
      count =
        comments
        |> Enum.filter(&ForgeProtocol.system_authored?(&1, bot))
        |> Enum.map(& &1["body"])
        |> Enum.count(&ForgeProtocol.step_run_marker?/1)

      {:ok, count}
    end
  end

  @doc """
  Extracts the last ` ```result ` block posted in a step_run comment — the `result_K`
  recorded by `StepRunCompleter` when the step advances toward a gatekeeper. Serves
  `StepDispatcher` to give the gatekeeper pod **what to judge** in its brief
  (option B: no branch clone). `:none` if none; `{:error, _}` HTTP/config.
  """
  @spec get_predecessor_result(String.t(), integer(), Keyword.t()) ::
          {:ok, map()} | :none | {:error, term()}
  def get_predecessor_result(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      # The ```result block feeds the gatekeeper's JUDGMENT BRIEF. Extract it
      # ONLY from SYSTEM comments — otherwise a forge user injects what the judge evaluates.
      comments
      |> Enum.filter(&ForgeProtocol.system_authored?(&1, bot))
      |> Enum.map(& &1["body"])
      |> Enum.reverse()
      |> Enum.find_value(:none, &ForgeProtocol.parse_result_block/1)
    end
  end

  defp get_issue_labels(config, repo, issue_number) do
    case http_get(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels") do
      {:ok, labels} when is_list(labels) -> {:ok, labels}
      {:error, _} = err -> err
    end
  end

  # ADD a label by NAME (POST = adds without replacing the existing). Gitea resolves the name against the
  # REPO **and ORG** labels server-side (`IssueLabelsOption.labels` = « strings representing label
  # names », swagger doc) → no more repo-id resolution client-side. The wire-protocol lock-labels
  # are created PER-REPO (`ensure_repo_label`, via the system account's repo-write): no org-ownership
  # required, and the routing state stays self-contained in its repo.
  #
  # SELF-HEAL: Gitea SILENTLY ignores a label name that exists NEITHER at the repo NOR at the org (POST
  # 200, but the label is NOT set) → the protocol lock would be a phantom → re-dispatch loop
  # (e.g. `lcars-awaits-arch` absent from the org). So we do NOT rely on the 200 alone: we VERIFY
  # that the label is in the response; absent → we CREATE it (repo's org) then retry; still
  # absent → fail-loud `{:label_not_added}` (never a lying :ok). No more dependence on hand-created
  # labels.
  defp add_issue_label(config, repo, issue_number, label_name) do
    case post_issue_label(config, repo, issue_number, label_name) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        with :ok <- ensure_repo_label(config, repo, label_name),
             {:ok, true} <- post_issue_label(config, repo, issue_number, label_name) do
          :ok
        else
          _ -> {:error, {:label_not_added, label_name}}
        end

      {:error, _} = err ->
        err
    end
  end

  # POST the label AND verify it is really set: the Gitea response = the issue's labels after
  # the add. An unknown name is silently ignored (200 without the label) → `{:ok, false}` (to be compensated).
  defp post_issue_label(config, repo, issue_number, label_name) do
    case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels", %{
           labels: [label_name]
         }) do
      {:ok, body} when is_list(body) -> {:ok, Enum.any?(body, &(&1["name"] == label_name))}
      {:ok, _non_list} -> {:ok, false}
      {:error, _} = err -> err
    end
  end

  # Creates the missing protocol label at the REPO level. The routing labels (`stage/*`/`wfmap/*`) and the
  # flat locks (`lcars-*`) live PER-REPO: the routing state belongs to ITS repo's issues (the
  # forge = state-store, self-contained per project), and the system account creates them via its **repo-write** —
  # never needing to be org-owner (which `POST /orgs/*/labels` would require → 403 « Must be an organization
  # owner »). Color + description PER FAMILY (the NAME carries the protocol, the description EXPLAINS it to
  # the human hovering over the label on the forge — before: the same cryptic string for all, « F-E5 » means
  # nothing outside the code). Tolerant: a failure (created concurrently) → `:ok` — it's the re-POST + its verification
  # that decide (otherwise `add_issue_label`'s fail-loud propagates).
  defp ensure_repo_label(config, repo, label_name) do
    # A SCOPED label (name `scope/value`, contains "/") is created MUTUALLY EXCLUSIVE (`exclusive:true`):
    # Gitea removes the old `scope/*` from the issue when a new one is set (verified forge 1.26.1, org AND
    # repo level, by NAME). This is the mechanism of `stage/*` (workflow_map position = visible state
    # machine): native unrepresentability (never 2 steps). The FLAT locks (`lcars-*`) are non-exclusive.
    body = %{
      name: label_name,
      exclusive: String.contains?(label_name, "/"),
      color: label_color(label_name),
      description: label_description(label_name)
    }

    case http_post(config, "/repos/#{encode_repo(repo)}/labels", body) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  # Cosmetic color (the NAME carries the protocol). The `stage/*` get a per-step tint for the
  # human glance (blue→amber→purple→green = brief-review→build→review→merged); the rest, neutral gray.
  defp label_color("stage/brief-review"), do: "#4a90d9"
  defp label_color("stage/build"), do: "#e08e0b"
  defp label_color("stage/review"), do: "#8e44ad"
  defp label_color("stage/merged"), do: "#2e9e5b"
  defp label_color(_), do: "#ededed"

  # Description PER FAMILY (Gitea tooltip on hover) — the NAME stays the protocol (LCARS vocab intact,
  # parsed as-is by the code), the description is the ONLY place where we explain in plain terms to a human
  # looking at the forge without the code in front of them. `wfmap/<map>` and `stage/<step>` have
  # dynamic values (map name / step name varying by workflow_map) → match on the PREFIX, not the
  # exact value (unlike `label_color`, which differentiates ONLY the 4 known stages).
  defp label_description("lcars-in-flight"),
    do:
      "Verrou : un pod travaille déjà cette brique (anti double-spawn). Levé par le système en fin de step — jamais à retirer à la main."

  defp label_description("lcars-awaits-arch"),
    do:
      "Cette issue attend une action HUMAINE via l'architecte (verdict escalade/halt/redirect) — le poller la laisse tranquille tant qu'il est posé."

  defp label_description("stage/" <> _step),
    do:
      "Étape COURANTE de cette issue dans son plan (workflow_map) — bouge à chaque avancée (mutex : une seule à la fois)."

  defp label_description("wfmap/" <> _map),
    do:
      "Le PLAN (workflow_map) que suit cette issue — posé UNE FOIS à l'onboarding, ne change jamais (fixe, pas un verrou)."

  defp label_description(_),
    do: "Label protocole LCARS (auto-créé, wire-protocol forge-state-machine)."

  # ============================================================
  # Forge identity — credential -> wire adapter (role token)
  # ============================================================

  @doc """
  Injects the ROLE account's token (`role`) into `forge_opts`, under the `:token` key that
  `resolve_config`/`resolve_token` re-read → the SYSTEM posts/merges IN THE ROLE'S NAME on the forge (avatar
  + honest trace). This is the SINGLE credential→wire adapter shared by `StepRunCompleter`, `StepDispatcher`
  and the gatekeeper seals.

  **Fail-CLOSED** (via the `Fleet.Credentials.RoleIdentity` smart-constructor): a role whose token is
  absent/unreadable/empty (or a non-path-safe role) → `{:error, :role_token_unavailable}`. It NEVER falls
  back to the system token — posting/merging as the most-privileged system account would be a privilege
  ESCALATION + a traceability lie. Load-bearing callers (gatekeeper seal, arch escalation) PROPAGATE the
  error (the op does not happen); cosmetic callers (eng voice, stopwatch) SKIP their post — losing a
  trace comment or a time entry, never the deliverable (the commit is already pushed) nor the
  pipeline. The pod never posts:
  it's the system that posts with the ROLE token, never the pod (forge-blind).
  """
  @spec as_role(keyword(), String.t() | nil) ::
          {:ok, keyword()} | {:error, :role_token_unavailable}
  def as_role(forge_opts, role) do
    case Fleet.Credentials.RoleIdentity.for_role(role) do
      {:ok, identity} -> {:ok, Keyword.put(forge_opts, :token, identity.token)}
      {:error, _} = err -> err
    end
  end
end
