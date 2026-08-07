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
  `get_issue/3`, `list_pulls/2`, `parse_feature_branch/1`, `pr_review_state/3`,
  `post_comment/4`, `close_issue/3`, `merged_pr_of_issue/3`). It CANNOT
  be adopted as a `@behaviour`: `Fleet.Pilot` does not depend on `Fleet.MCP` and the compile reference
  would be a Boundary violation (`Fleet.MCP` is absent from `Fleet.Pilot`'s `use Boundary` deps →
  compile error). Duck-typed impl — any evolution of
  these 9 signatures MUST be mirrored onto the behaviour's `@callback`s (and vice versa).

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

  import Fleet.Pilot.ForgeClient.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_patch: 3,
      http_delete: 2,
      http_delete_body: 3,
      paginate: 3,
      forge_bot_login: 2
    ]

  import Fleet.Pilot.ForgeClient.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  defdelegate parse_feature_branch(head), to: ForgeProtocol

  defdelegate branch_head(repo, branch, opts), to: Fleet.Pilot.ForgeClient.Repo

  @doc """
  Adds and verifies a label, returning `:already_present` without writing when applicable.

  Missing protocol labels are created at repository scope and retried; unverifiable success returns
  `{:error, {:label_not_added, label_name}}`.
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
  Lists all open issues visible to the optional forge-side `:assigned_by` scope.
  """
  @spec list_open_issues(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_issues(repo, opts \\ []) when is_binary(repo) do
    list_scoped_issues(repo, "issues", opts)
  end

  # (`assigned_by` — Gitea 1.26.1 works on /issues for both types) → the poller sees
  defp list_scoped_issues(repo, type, opts) when type in ["issues", "pulls"] do
    state = Keyword.get(opts, :state, "open")

    with {:ok, config} <- resolve_config(opts) do
      paginate(
        config,
        "/repos/#{encode_repo(repo)}/issues",
        "state=#{state}&type=#{type}" <> assigned_by_qs(opts)
      )
    end
  end

  @doc false
  def assigned_by_qs(opts) do
    case Keyword.get(opts, :assigned_by) do
      login when is_binary(login) and login != "" -> "&assigned_by=" <> URI.encode_www_form(login)
      _ -> ""
    end
  end

  @doc """
  Reads an issue by number, including state, labels, and assignees.
  """
  @spec get_issue(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def get_issue(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      http_get(config, "/repos/#{encode_repo(repo)}/issues/#{number}")
    end
  end

  @doc """
  Lists every issue comment oldest-first; the final element is therefore the true newest comment.
  """
  @spec list_comments(String.t(), integer(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      paginate(config, "/repos/#{encode_repo(repo)}/issues/#{number}/comments", "")
    end
  end

  @doc """
  Replaces issue assignees with exactly `login`, returning `:already` when converged.
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

  @doc """
  Posts a comment, deduplicating `:dedup_signature` only against authenticated system comments.

  If the bot identity or comment history cannot be resolved, no existing marker is trusted and the
  comment is posted.
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
  Removes an attached label, returning `:already_absent` when converged.
  """
  @spec remove_label(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :removed | :already_absent} | {:error, term()}
  def remove_label(repo, issue_number, label_name, opts \\ [])
      when is_binary(label_name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, current} <- get_issue_labels(config, repo, issue_number) do
      # Attached-label ids cover repository and organization labels.
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

  @doc """
  Starts native time tracking on an issue or PR. An already-active stopwatch succeeds.
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
  Stops native time tracking. An already-stopped stopwatch succeeds.
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
  Closes the issue, and SAYS WHICH KIND OF CLOSURE IT IS. PATCH `state: closed`, idempotent on the
  Gitea side.

  `:closure` is MANDATORY — an unnamed closure is refused, loudly, rather than defaulted:

    * `:delivered` — the work landed (seal after merge, terminal step). Stamps `stage/merged`.
    * `:retired` — the ticket dies WITHOUT delivering: its work moved (supersede) or was dropped.
      Stamps `stage/retired`.
    * `:marker` — not a ticket at all (parking markers of `ProjectOnboard`). Stamps nothing.

  WHY THE ARGUMENT IS REQUIRED, AND NOT DERIVED. Until now "a closed ticket is a delivered ticket"
  was EMERGENT: it held because no actor owns a close gesture — the human's team is `read`, the
  architect has no close tool, and every closing path is runtime. An invariant resting on the
  absence of a tool is one new caller away from lying, and everything downstream reads the CLOSURE,
  never the intent: a dependency releases on a closed blocker whatever killed it.

  Deriving the kind from "does it carry `stage/merged`?" would rebuild the same weakness one level
  up — an ABSENCE is not a fact, and the reader would have to guess what silence means. Here the
  caller states it at the only moment where it is known for certain.

  The stamp is best-effort and the close is not rolled back for it: the closure is authoritative,
  the label is its trace. A failed stamp is logged, never swallowed.
  """
  @spec close_issue(String.t(), integer(), Keyword.t()) :: {:ok, :closed} | {:error, term()}
  def close_issue(repo, issue_number, opts \\ []) do
    with {:ok, kind} <- fetch_closure_kind(opts),
         {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_patch(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}", %{
             state: "closed"
           }) do
      stamp_closure(repo, issue_number, kind, opts)
      {:ok, :closed}
    end
  end

  defp fetch_closure_kind(opts) do
    case Keyword.get(opts, :closure) do
      kind when kind in [:delivered, :retired, :marker] ->
        {:ok, kind}

      other ->
        {:error,
         {:closure_kind_required,
          "close_issue: `closure:` manquant ou invalide (#{inspect(other)}) — une fermeture qui " <>
            "ne dit pas si elle LIVRE ou si elle RETIRE laisse tout l'aval deviner"}}
    end
  end

  defp stamp_closure(_repo, _n, :marker, _opts), do: :ok

  defp stamp_closure(repo, n, kind, opts) do
    stage =
      case kind do
        :delivered -> Fleet.Labels.stage_merged()
        :retired -> Fleet.Labels.stage_retired()
      end

    label = Fleet.Labels.stage_prefix() <> stage

    case add_label(repo, n, label, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ForgeClient: #{repo}##{n} closed (#{kind}) but the `#{label}` stamp FAILED " <>
            "(#{inspect(reason)}) — the closure stands, its nature is not readable on the ticket"
        )

        :ok
    end
  end

  @doc """
  The issues BLOCKING `number` (what it waits on), as returned by the forge.

  Gitea carries issue dependencies natively and enforces them where it matters: it refuses to CLOSE
  an issue while a blocker is still open. So this is a read, never a rule we re-implement — same
  stance as branch-protection.

  ⚠ A CLOSED blocker counts as satisfied. That is what makes the supersede path load-bearing: a
  retired ticket keeps the edges pointing at it, and closing it RELEASES everything it blocked —
  while the work moved to its replacement and is not delivered (measured 2026-08-04 on the bench).
  """
  @spec issue_dependencies(String.t(), integer(), Keyword.t()) ::
          {:ok, [map()]} | {:error, term()}
  def issue_dependencies(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      paginate(config, "/repos/#{encode_repo(repo)}/issues/#{number}/dependencies", "")
    end
  end

  @doc "The issues `number` BLOCKS (the inverse edge of `issue_dependencies/3`)."
  @spec issue_blocks(String.t(), integer(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def issue_blocks(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      paginate(config, "/repos/#{encode_repo(repo)}/issues/#{number}/blocks", "")
    end
  end

  @doc """
  Adds "`number` depends on `blocker`" (same repo).

  THE BODY FIELD IS `repo`, NOT `name`. The swagger's `IssueMeta` says `name`; sending it yields
  `404 IsErrRepoNotExist [id: 0, uid: 0]` — an error that accuses the repository while the body is
  what is wrong. Measured against a live Gitea 1.26.1 on 2026-08-04; both spellings were tried.
  """
  @spec add_issue_dependency(String.t(), integer(), integer(), Keyword.t()) ::
          {:ok, map()} | {:error, term()}
  def add_issue_dependency(repo, number, blocker, opts \\ [])
      when is_binary(repo) and is_integer(number) and is_integer(blocker) do
    [owner, name] = String.split(repo, "/", parts: 2)

    with {:ok, config} <- resolve_config(opts) do
      http_post(
        config,
        "/repos/#{encode_repo(repo)}/issues/#{number}/dependencies",
        %{index: blocker, owner: owner, repo: name}
      )
    end
  end

  @doc """
  Removes "`number` depends on `blocker`" (same repo). Inverse of `add_issue_dependency/4`.

  Same body shape and the same `repo`-not-`name` trap: the edge is identified by the OBJECT, so the
  DELETE carries a body (see `Transport.http_delete_body/3`).

  Needed because a retirement must not leave its edges behind. Closing a blocker RELEASES what it
  blocked, so a dependent whose blocker is retired would silently become closable as if the work had
  landed — the retired ticket delivered nothing. Lifting the edge and NAMING the retirement on the
  dependent is what keeps "unblocked" from meaning "done".
  """
  @spec remove_issue_dependency(String.t(), integer(), integer(), Keyword.t()) ::
          {:ok, map()} | {:error, term()}
  def remove_issue_dependency(repo, number, blocker, opts \\ [])
      when is_binary(repo) and is_integer(number) and is_integer(blocker) do
    [owner, name] = String.split(repo, "/", parts: 2)

    with {:ok, config} <- resolve_config(opts) do
      http_delete_body(
        config,
        "/repos/#{encode_repo(repo)}/issues/#{number}/dependencies",
        %{index: blocker, owner: owner, repo: name}
      )
    end
  end

  @doc "Org repos (WS3 discovery, org-membership = admission). See `ForgeClient.Repo.list_org_repos/2`."
  def list_org_repos(org, opts \\ []), do: Repo.list_org_repos(org, opts)

  @doc "Numeric forge id of the repo. See `Fleet.Pilot.ForgeClient.Repo.repo_id/2`."
  def repo_id(repo, opts \\ []), do: Repo.repo_id(repo, opts)

  @doc """
  Creates an issue and returns its number. `:assignees` are logins; `:labels` are numeric ids.
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

  @doc """
  Resolves a repository label name to its numeric id across all pages.

  Returns `{:error, {:label_unknown, name}}` when absent; callers can require labels that must be
  present atomically at issue creation.
  """
  @spec repo_label_id(String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def repo_label_id(repo, name, opts \\ []) when is_binary(repo) and is_binary(name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, labels} <- paginate(config, "/repos/#{encode_repo(repo)}/labels", "") do
      case Enum.find(labels, &(&1["name"] == name)) do
        %{"id" => id} -> {:ok, id}
        _ -> {:error, {:label_unknown, name}}
      end
    end
  end

  @doc """
  Opens a pull request and returns its number. On conflict, resolves the existing open PR for the
  same head and base. Issue closure remains an explicit post-seal operation.
  """
  @spec open_pr(String.t(), String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def open_pr(repo, head, base, title, opts \\ [])
      when is_binary(repo) and is_binary(head) and is_binary(base) and is_binary(title) do
    with {:ok, config} <- resolve_config(opts) do
      attrs = %{head: head, base: base, title: title, body: Keyword.get(opts, :body, "")}

      case http_post(config, "/repos/#{encode_repo(repo)}/pulls", attrs) do
        {:ok, %{"number" => number}} -> {:ok, number}
        {:error, {:http, 409, _}} -> get_pr_for_branch(repo, head, base, opts)
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Creates a branch from a server-known ref, separately from the later content push so their feed
  events can be spaced. Returns `{:error, :branch_exists}` on conflict.
  """
  @spec create_branch(String.t(), String.t(), String.t(), Keyword.t()) :: :ok | {:error, term()}
  def create_branch(repo, branch, old_ref, opts \\ [])
      when is_binary(repo) and is_binary(branch) and is_binary(old_ref) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/branches", %{
             "new_branch_name" => branch,
             "old_ref_name" => old_ref
           }) do
        {:ok, _} -> :ok
        {:error, {:http, 409, _}} -> {:error, :branch_exists}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Finds an open PR by exact head and base across every page, or returns `:pr_not_found`.
  """
  @spec get_pr_for_branch(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def get_pr_for_branch(repo, head, base, opts \\ [])
      when is_binary(repo) and is_binary(head) and is_binary(base) do
    with {:ok, config} <- resolve_config(opts) do
      case paginate(config, "/repos/#{encode_repo(repo)}/pulls", "state=open") do
        {:ok, pulls} ->
          case Enum.find(pulls, &pr_matches_head?(&1, head, base)) do
            %{"number" => number} -> {:ok, number}
            _ -> {:error, :pr_not_found}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp pr_matches_head?(pr, head, base) do
    get_in(pr, ["head", "ref"]) == head and get_in(pr, ["base", "ref"]) == base
  end

  @doc """
  Requests native PR reviews from the supplied logins.
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
  Posts an approval, change request, or comment as a native durable PR review.
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
  Closes a pull request WITHOUT merging it — PATCH `state: closed`.

  It exists because retiring a ticket did not retire its work. The two rails are independent by
  design: `dispatch_review` polls PULLS, not issues, and it is not lease-guarded. So a supersede
  that closed the ticket while its PR stayed open left that PR being judged, then merged, into a
  retired ticket — measured on the bench 2026-08-04.

  The supersede used to REFUSE the gesture instead (`supersedes_target_in_flight`), which read like
  a policy ("let it land") and was in fact a workaround for this missing capability: nothing in the
  whole forge client could close a pull. A retirement that cannot retire the work is not a
  retirement, and the operator's intent — stop the machine, bound the cost — does not care whether
  a PR exists.

  Idempotent on the Gitea side, like every close.
  """
  @spec close_pr(String.t(), integer(), Keyword.t()) :: {:ok, :closed} | {:error, term()}
  def close_pr(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_patch(config, "/repos/#{encode_repo(repo)}/pulls/#{index}", %{state: "closed"}) do
      {:ok, :closed}
    end
  end

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

  defp merge_checking?(body) when is_map(body),
    do: body |> Map.get("message", "") |> String.downcase() |> String.contains?("try again later")

  defp merge_checking?(_), do: false

  defp delete_head_branch_spaced(config, repo, index) do
    with {:ok, pr} <- http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}"),
         head_ref when is_binary(head_ref) and head_ref != "" <- get_in(pr, ["head", "ref"]) do
      Fleet.Pilot.WriteSpacing.gap()

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
  Lists full open PR records under the optional forge-side assignee scope.

  Hybrid (Gitea 1.26.1): `/pulls` does NOT have `assigned_by`, but `/issues?type=pulls&assigned_by`
  Gitea exposes that filter only on the issue-shaped PR list, so each filtered number is expanded
  with `get_pull/3`. Any failed expansion fails the whole read.
  """
  @spec list_open_pulls(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_pulls(repo, opts \\ []) when is_binary(repo) do
    with {:ok, pr_issues} <- list_scoped_issues(repo, "pulls", opts) do
      pr_issues |> Enum.map(& &1["number"]) |> fetch_pulls(repo, opts)
    end
  end

  # Fetches the COMPLETE shape of each PR (head/head.sha/requested_reviewers) for the filtered
  # numbers. Fail-fast preserved: an error on a single PR fails the whole set — we never dispatch on
  # a partial view, the same rule as pagination.
  #
  # ─── POURQUOI N REQUETES, ET POURQUOI ELLES SONT MAINTENANT PARALLELES (BL-6-40) ──────────────
  # The N+1 is STRUCTURAL on the forge side: Gitea 1.26's `/pulls` does not carry `assigned_by`, so
  # scoping goes through `/issues?type=pulls` — which returns ISSUE objects, with no `head.sha` and
  # no `requested_reviewers`. Hence one `get_pull` per number, and no workaround removes it until
  # the forge returns the field.
  #
  # What IS removable is the SEQUENTIALITY. These requests are independent and side-effect free;
  # chaining them made the tick pay the SUM of the latencies where the maximum suffices.
  # `max_concurrency: 8` and not unbounded: they share the ForgeClient's Finch pool, and opening N
  # connections to a forge to read N PRs would trade slowness for saturation.
  #
  # ⚠ The `updated_at` workaround (cache the complete shape and re-read only the modified PRs) is
  # deliberately NOT DONE: the invalidation key would be `updated_at`, so a single Gitea mutation
  # that does not bump it would serve a STALE PR to a merge decision. It demands VERIFYING which
  # mutations bump it (review submitted, push on the head, reviewer change), not assuming it.
  defp fetch_pulls(numbers, repo, opts) do
    numbers
    |> Task.async_stream(&get_pull(repo, &1, opts),
      max_concurrency: 8,
      ordered: true,
      # A PR's timeout is already bounded by the transport (`receive_timeout`); this one is the net
      # for the case where the Task itself hangs. `:kill_task` rather than a propagated exit: a PR
      # that does not answer becomes an error of THAT PR, not a crash of the poller.
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, pr}}, {:ok, acc} -> {:cont, {:ok, [pr | acc]}}
      {:ok, {:error, _} = err}, _acc -> {:halt, err}
      {:exit, reason}, _acc -> {:halt, {:error, {:pull_fetch_crashed, reason}}}
    end)
    |> case do
      {:ok, prs} -> {:ok, Enum.reverse(prs)}
      err -> err
    end
  end

  @doc """
  Lists full open and closed PR records. This N+1 status read preserves review history after merge.
  """
  @spec list_pulls(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_pulls(repo, opts \\ []) when is_binary(repo) do
    with {:ok, pr_issues} <- list_scoped_issues(repo, "pulls", Keyword.put(opts, :state, "all")) do
      pr_issues |> Enum.map(& &1["number"]) |> fetch_pulls(repo, opts)
    end
  end

  @doc "GET a single PR → full shape (head/head.sha/requested_reviewers). Building block of list_open_pulls."
  @spec get_pull(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def get_pull(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts),
         do: http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{number}")
  end

  @doc """
  Counts comments containing `prefix` across all pages. Counting is author-agnostic because a forged
  extra marker can only tighten the consuming budget.
  """
  @spec count_comments_marked(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_comments_marked(repo, issue_number, prefix, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) and is_binary(prefix) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, comments} <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      {:ok, Enum.count(comments, &String.contains?(&1["body"] || "", prefix))}
    end
  end

  @doc """
  Resolves the merged PR from the latest `[merge:pr-N]` issue marker, not from rewritten branch refs.

  names: Gitea (1.26.4, verified live 2026-07-19) REWRITES a merged PR's `head.ref` to
  Returns `:none` only after a successful complete comment read. The marker is author-agnostic because
  it is observability-only and the gatekeeper role, not necessarily the system bot, writes it.
  """
  @spec merged_pr_of_issue(String.t(), integer(), Keyword.t()) ::
          {:ok, map()} | :none | {:error, term()}
  def merged_pr_of_issue(repo, issue_number, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, comments} <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      comments
      |> Enum.reverse()
      |> Enum.find_value(fn c ->
        case ForgeProtocol.parse_merge_marker(c["body"] || "") do
          {:ok, n} -> n
          :error -> nil
        end
      end)
      |> case do
        nil -> :none
        pr_number -> get_pull(repo, pr_number, opts)
      end
    end
  end

  @doc "Jury state (verdicts + jury SET + outcome) of a PR. See `Fleet.Pilot.ForgeClient.Jury.pr_review_state/3`."
  def pr_review_state(repo, index, opts \\ []), do: Jury.pr_review_state(repo, index, opts)

  @doc "Feedback of the REQUEST_CHANGES in force. See `Fleet.Pilot.ForgeClient.Jury.change_request_feedback/3`."
  def change_request_feedback(repo, index, opts \\ []),
    do: Jury.change_request_feedback(repo, index, opts)

  @doc """
  Counts the largest same-base group of durable publish-failure markers for issue `n`.

  A successful push advances the base, so each group is one consecutive failure streak.
  """
  @spec count_publish_failures(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_publish_failures(repo, n, opts \\ []) when is_binary(repo) and is_integer(n) do
    with {:ok, comments} <- list_comments(repo, n, opts) do
      streak =
        comments
        |> Enum.map(&ForgeProtocol.parse_publish_fail_marker(Map.get(&1, "body", "")))
        |> Enum.filter(&match?({:ok, {^n, _}}, &1))
        |> Enum.frequencies()
        |> Map.values()
        |> Enum.max(fn -> 0 end)

      {:ok, streak}
    end
  end

  @doc "Counts the rework rounds. See `Fleet.Pilot.ForgeClient.Jury.count_change_request_rounds/3`."
  def count_change_request_rounds(repo, index, opts \\ []),
    do: Jury.count_change_request_rounds(repo, index, opts)

  @doc """
  Worst CI state on `sha` — `:success | :pending | :failure | :none` (Gitea
  `GET /repos/{repo}/commits/{sha}/statuses`).

  WHY A WORST-OF AND NOT THE RAW LIST. A commit carries ONE context per workflow-job-trigger pair,
  so a Gitea Actions run posts BOTH `CI / ci (push)` and `CI / ci (pull_request)` on the same sha
  (measured 2026-08-03). The caller's question is never "which contexts exist" but "may this merge
  proceed", and a single failure answers it — reducing here keeps that judgement in one place
  instead of leaving each caller to re-derive it, differently.

  `:none` (no status at all) is DISTINCT from `:success` on purpose: a repo with no CI and a repo
  whose CI passed are not the same fact, and collapsing them would let "the rail never ran" wear
  the face of "the rail is green". The caller decides what an absent rail means for it.

  Statuses are returned newest-first per context; we keep the FIRST occurrence of each context —
  an older green must never outvote the current red on the same context.
  """
  @spec commit_ci_state(String.t(), String.t(), Keyword.t()) ::
          {:ok, :success | :pending | :failure | :none} | {:error, term()}
  def commit_ci_state(repo, sha, opts \\ []) when is_binary(repo) and is_binary(sha) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, statuses} <-
           paginate(config, "/repos/#{encode_repo(repo)}/commits/#{encode_seg(sha)}/statuses", "") do
      latest =
        statuses
        |> Enum.reduce(%{}, fn st, acc ->
          # `status`, jamais `state` : le contrat porte `state` sur CombinedStatus (l'agregat),
          # `status` sur CommitStatus (l'element), et cet appel liste des CommitStatus. Un repli
          # sur `state` ici ne pourrait jamais tirer et se lirait comme une couverture.
          Map.put_new(acc, st["context"], st["status"])
        end)
        |> Map.values()

      {:ok, worst_ci_state(latest)}
    end
  end

  # Worst-of, in the order that matters to a merge decision: one failure sinks it; otherwise any
  # unfinished run means "not yet", never "yes".
  defp worst_ci_state([]), do: :none

  defp worst_ci_state(states) do
    cond do
      Enum.any?(states, &(&1 in ["failure", "error"])) -> :failure
      Enum.any?(states, &(&1 == "pending")) -> :pending
      Enum.all?(states, &(&1 == "success")) -> :success
      # An unknown state string is NOT read as success: a forge that grows a new state must not
      # widen the merge door by default.
      true -> :pending
    end
  end

  @doc "Judges re-requested after judgment (timeline). See `Fleet.Pilot.ForgeClient.Jury.pr_rerequested_reviewers/3`."
  def pr_rerequested_reviewers(repo, index, opts \\ []),
    do: Jury.pr_rerequested_reviewers(repo, index, opts)

  defp comment_signed?(config, repo, issue_number, sig, opts) do
    case paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      {:ok, comments} when is_list(comments) ->
        # Counted markers trust the system author; observability markers may opt into any author.
        trusted =
          if Keyword.get(opts, :dedup_any_author, false) do
            comments
          else
            case forge_bot_login(config, opts) do
              {:ok, bot} -> Enum.filter(comments, &ForgeProtocol.system_authored?(&1, bot))
              {:error, _} -> []
            end
          end

        Enum.any?(trusted, fn c -> String.contains?(c["body"] || "", sig) end)

      _ ->
        false
    end
  end

  @stage_prefix Fleet.Labels.stage_prefix()
  @wfmap_prefix Fleet.Labels.wfmap_prefix()

  @doc """
  Sets an issue's fixed `wfmap/<pipeline>` and exclusive current `stage/<step>` labels.
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
  Sets only the exclusive current stage, retaining the issue's workflow-map label.
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
  Reads `{workflow_map, stage}` from scoped labels. A missing half returns `:none`; no default map is
  invented.
  """
  @spec get_route(String.t(), integer(), Keyword.t()) ::
          {:ok, {String.t(), String.t()}} | :none | {:error, term()}
  def get_route(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, labels} <- get_issue_labels(config, repo, issue_number) do
      route_from_labels(labels)
    end
  end

  @doc """
  La route DERIVEE de labels deja en main — pure, zero I/O (BL-6-40 Phase 2).

  `get_route/3` fait un `GET /issues/{n}/labels` par issue et par tick. Or l'appelant chaud
  (`Poller.Lease.classify_issue`) tient DEJA les labels complets : `list_open_issues` les rend avec
  l'issue. Une requete par issue, par repo, par tick, pour une donnee qui est en RAM.

  Deux formes acceptees parce que les deux existent chez les appelants : la forme FIL (maps Gitea
  `%{"name" => …}`, ce que rend `get_issue_labels`) et la liste de NOMS (ce que `classify_issue`
  a deja projete). Accepter les deux evite d'imposer une re-projection a un appelant qui a
  justement fait l'economie.

  `get_route/3` reste, et n'est pas un doublon : un appelant qui n'a pas l'objet issue — une sonde,
  un outil, un chemin qui part d'un numero — ne peut pas deriver ce qu'il n'a pas lu. Il delegue
  ici apres avoir lu, donc la REGLE de derivation n'existe qu'une fois.
  """
  @spec route_from_labels([map() | String.t()]) :: {:ok, {String.t(), String.t()}} | :none
  def route_from_labels(labels) when is_list(labels) do
    normalized =
      Enum.map(labels, fn
        %{"name" => n} -> %{"name" => n}
        n when is_binary(n) -> %{"name" => n}
        _ -> %{"name" => nil}
      end)

    case {current_wfmap(normalized), current_stage(normalized)} do
      {map, step} when is_binary(map) and is_binary(step) -> {:ok, {map, step}}
      _ -> :none
    end
  end

  defp stage_label(step) when is_binary(step), do: @stage_prefix <> step
  defp wfmap_label(map) when is_binary(map), do: @wfmap_prefix <> map

  defp current_stage(labels), do: label_value(labels, @stage_prefix)
  defp current_wfmap(labels), do: label_value(labels, @wfmap_prefix)

  defp label_value(labels, prefix) when is_list(labels) do
    Enum.find_value(labels, fn label ->
      name = label["name"]

      if is_binary(name) and String.starts_with?(name, prefix),
        do: String.replace_prefix(name, prefix, "")
    end)
  end

  @doc """
  Counts system-authored step-run markers across all comment pages for the anti-runaway budget.

  An unverifiable bot or page is an error, never a permissive undercount.
  """
  @spec count_signed_step_runs(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_signed_step_runs(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      count =
        comments
        |> Enum.filter(&ForgeProtocol.system_authored?(&1, bot))
        |> Enum.map(& &1["body"])
        |> Enum.count(&ForgeProtocol.step_run_marker?/1)

      {:ok, count}
    end
  end

  @doc """
  Extracts the latest result block from system-authored comments for the next judge's brief.
  """
  @spec get_predecessor_result(String.t(), integer(), Keyword.t()) ::
          {:ok, map()} | :none | {:error, term()}
  def get_predecessor_result(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
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

  defp post_issue_label(config, repo, issue_number, label_name) do
    case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels", %{
           labels: [label_name]
         }) do
      {:ok, body} when is_list(body) -> {:ok, Enum.any?(body, &(&1["name"] == label_name))}
      {:ok, _non_list} -> {:ok, false}
      {:error, _} = err -> err
    end
  end

  @doc """
  Ensures static lock, genre, and stage labels exist with their protocol metadata.

  Success is based on complete readback, not create responses. Missing or unreadable labels return
  `:labels_missing` or `:labels_unverifiable`; dynamic workflow-map labels are not seeded.
  """
  @spec ensure_protocol_labels(String.t(), keyword()) :: :ok | {:error, term()}
  def ensure_protocol_labels(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts) do
      statics =
        [
          "lcars-in-flight",
          "lcars-awaits-arch",
          # Genre marker (chantier face-projet): the arch poses it at create_issue, the burn reads
          # it — it must exist on every fleet repo or add_label fails the ticket's genre silently.
          "genre/ops",
          "stage/brief-review",
          "stage/build",
          "stage/review",
          "stage/merged"
        ] ++ Fleet.Labels.visual_types()

      Enum.each(statics, &ensure_repo_label(config, repo, &1))
      verify_labels_present(config, repo, statics)
    end
  end

  defp verify_labels_present(config, repo, expected) do
    case paginate(config, "/repos/#{encode_repo(repo)}/labels", "") do
      {:ok, labels} when is_list(labels) ->
        present = MapSet.new(labels, & &1["name"])

        case Enum.reject(expected, &MapSet.member?(present, &1)) do
          [] -> :ok
          missing -> {:error, {:labels_missing, missing}}
        end

      other ->
        {:error, {:labels_unverifiable, other}}
    end
  end

  # Creates the missing protocol label at the REPO level. The routing labels (`stage/*`/`wfmap/*`) and the
  # flat locks (`lcars-*`) live PER-REPO: the routing state belongs to ITS repo's issues (the
  # forge = state-store, self-contained per project), and the system account creates them via its **repo-write** —
  # never needing to be org-owner (which `POST /orgs/*/labels` would require → 403 "Must be an organization
  # owner"). Color + description PER FAMILY (the NAME carries the protocol, the description EXPLAINS it to
  # the human hovering over the label on the forge — a cryptic protocol string means
  # nothing outside the code). TRUE idempotence = check-then-create: Gitea does NOT reject a
  # duplicate label NAME (no 409 — verified live 2026-07-18: a double template sync left every
  # label twice, faithfully copied into every generated repo). A failed existence read falls
  # through to the POST (the label matters more than the dedup); a failed POST stays tolerated
  # (`:ok` — it's the re-POST + its verification that decide, cf. `add_issue_label`).
  defp ensure_repo_label(config, repo, label_name) do
    case paginate(config, "/repos/#{encode_repo(repo)}/labels", "") do
      {:ok, labels} when is_list(labels) ->
        case Enum.find(labels, &(&1["name"] == label_name)) do
          nil -> create_repo_label(config, repo, label_name)
          existing -> reconcile_label_color(config, repo, existing, label_name)
        end

      _ ->
        create_repo_label(config, repo, label_name)
    end
  end

  # An already-present label keeps its id, and with it every issue wearing it — only its COLOR is
  # reconciled. Creating-only would leave every repo seeded before the palette wearing the old
  # near-white default, and the marker that motivated the palette (`genre/ops`) is precisely one
  # that already exists on all of them: a fix that only reaches repos nobody has created yet is not
  # a fix. Best-effort by design — a repo whose labels cannot be repainted still routes correctly,
  # so this never turns a working forge into a failed seeding.
  defp reconcile_label_color(config, repo, %{"id" => id, "color" => current}, label_name) do
    wanted = label_color(label_name)

    if normalize_color(current) == normalize_color(wanted) do
      :ok
    else
      _ = http_patch(config, "/repos/#{encode_repo(repo)}/labels/#{id}", %{color: wanted})
      :ok
    end
  end

  defp reconcile_label_color(_config, _repo, _existing, _label_name), do: :ok

  # Gitea answers `"ededed"` and accepts `"#ededed"` — comparing the two raw would repaint every
  # label on every pass, forever.
  defp normalize_color(color) when is_binary(color),
    do: color |> String.trim_leading("#") |> String.downcase()

  defp normalize_color(_), do: ""

  defp create_repo_label(config, repo, label_name) do
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

  # The NAME carries the protocol; the color carries the GLANCE. Operator palette, 2026-08-03.
  #
  # The former default was `#ededed` — near-white on a white UI. Every label outside the four
  # `stage/*` landed there, so `genre/ops` was invisible on the very tickets whose genre it
  # declares: present in the API, absent to the human. A label nobody can see is a label that is
  # not there, and it fails silently in the one direction that matters (an operator scanning a
  # list concludes the marker was never posed).
  #
  # One tint per PROTOCOL family, and the four `stage/*` keep a progression readable without a
  # legend (blue → yellow → purple → green = brief-review → build → review → merged). The palette
  # is reserved for labels that MEAN something mechanically; the decorative `type:*` register gets
  # a visible neutral instead of borrowing a protocol tint, so a color rhyme never suggests a
  # kinship the code does not have.
  defp label_color("lcars-in-flight"), do: "#FF9900"
  defp label_color("lcars-awaits-arch"), do: "#CC6666"
  defp label_color("genre/ops"), do: "#33BBCC"
  defp label_color("stage/brief-review"), do: "#6699CC"
  defp label_color("stage/build"), do: "#FFCC33"
  defp label_color("stage/review"), do: "#9966CC"
  defp label_color("stage/merged"), do: "#99CC66"
  defp label_color("wfmap/" <> _map), do: "#CC99CC"
  defp label_color("type:" <> _kind), do: "#999999"
  defp label_color(_), do: "#999999"

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

  defp label_description("wfmap/" <> map) do
    case card_description(map) do
      {:ok, desc} ->
        String.slice(
          "Le PLAN (workflow_map) de cette issue — posé à l'onboarding, fixe. Carte : " <> desc,
          0,
          240
        )

      :error ->
        "Le PLAN (workflow_map) que suit cette issue — posé UNE FOIS à l'onboarding, ne change jamais (fixe, pas un verrou)."
    end
  end

  defp label_description("genre/ops"),
    do:
      "Ticket DOCUMENTAIRE : le système l'aiguille vers la voie ops (branche work/ops) au lieu de la voie code. Posé à la création, lu une fois — c'est lui qui route, pas le `type:`."

  defp label_description("type:" <> _kind),
    do:
      "Type VISUEL du ticket — décoratif, aucun mécanisme ne le lit. Il suit le genre : ce qui ROUTE est `genre/*`."

  defp label_description(_),
    do: "Label protocole LCARS (auto-créé, wire-protocol forge-state-machine)."

  defp card_description(map) do
    case Fleet.Workflow.Loader.load!(map)["description"] do
      desc when is_binary(desc) and desc != "" -> {:ok, desc}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Replaces forge credentials with a role token so the system acts under that role's identity.

  Invalid, missing, unreadable, or empty role credentials return `:role_token_unavailable`; there is
  no fallback to the privileged system token. Pods remain forge-blind.
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
