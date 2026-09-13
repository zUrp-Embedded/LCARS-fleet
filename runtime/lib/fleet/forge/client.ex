defmodule Fleet.Forge.Client do
  @moduledoc """
  Gitea operations for issues, PRs, jury state and onboarding, exposed through forge-client seams.
  Transport handles HTTP/config/pagination; Protocol owns marker and branch formats.
  Delegates remain here when callers reach them through this facade.

  Implements MCP.PodTools.Delegation.ForgeClient by convention: a @behaviour reference would
  reverse the Boundary dependency. Keep signatures aligned with its callbacks; Delegation.Gate
  checks exported functions, not full return semantics. The same applies to the ForgeWriter seam.

  Transport merges call options over :pilot_forge, then selects a nonempty token source in order:
  :token, :token_file, :account. Sources are not mutually exclusive; no source returns a named
  error without reading a personal fallback file. :req_options are forwarded to Req.

  Writes have per-operation replay rules, not general idempotence: issue/review creation can
  duplicate, and comment dedup is a read-then-write race. Multi-request operations are not
  transactional; a returned error can follow an applied write. Paginated reads propagate errors
  and budget refusals, but depend on server counts/page behavior and are not atomic snapshots.
  """

  require Logger

  alias Fleet.Forge.Client.CI
  alias Fleet.Forge.Client.Jury
  alias Fleet.Forge.Client.Labels
  alias Fleet.Forge.Client.Merge
  alias Fleet.Forge.Client.Repo
  alias Fleet.Forge.Client.Signing
  alias Fleet.Forge.Protocol, as: ForgeProtocol

  import Fleet.Forge.Client.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_patch: 3,
      http_delete: 2,
      http_delete_body: 3,
      paginate: 3,
      forge_bot_login: 2,
      login_of: 1
    ]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  @spec parse_feature_branch(term()) :: {:ok, {integer(), String.t()}} | :error
  defdelegate parse_feature_branch(head), to: ForgeProtocol

  @spec branch_head(String.t(), String.t(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate branch_head(repo, branch, opts), to: Repo

  # ForgeWriter's default names this facade; extracting Files must preserve its seam exports.
  @spec put_file(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, term()} | {:error, term()}
  defdelegate put_file(repo, path, content, opts), to: Fleet.Forge.Client.Files

  # mcp_probe_forge_client also calls get_file here, without a behavior conformance check;
  # a missing delegate would raise UndefinedFunctionError at the tool call.
  @spec get_file(String.t(), String.t(), Keyword.t()) ::
          {:ok, %{content: String.t(), sha: String.t()}} | {:error, term()}
  defdelegate get_file(repo, path, opts), to: Fleet.Forge.Client.Files

  @doc """
  Adds and verifies a label, returning `:already_present` without writing when applicable.

  If a successful POST omits the requested name, attempts repo-level creation/reconciliation
  and one re-add. An unverifiable retry returns {:error, {:label_not_added, label_name}};
  initial HTTP errors propagate. Verification checks the POST response, not a later read.
  """
  @spec add_label(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :added | :already_present}
          | {:error, term()}
  def add_label(repo, issue_number, label_name, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) and is_binary(label_name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, current} <- Labels.get_issue_labels(config, repo, issue_number),
         current_names = Enum.map(current, & &1["name"]),
         false <- label_name in current_names && :already_present,
         :ok <- Labels.add_issue_label(config, repo, issue_number, label_name) do
      {:ok, :added}
    else
      :already_present -> {:ok, :already_present}
      {:error, _} = err -> err
    end
  end

  @doc """
  Paginates issue records with state defaulting to open (overridable by :state) and optional
  forge-side :assigned_by scope. No local assignee filtering or record-shape validation.
  """
  @spec list_open_issues(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_issues(repo, opts \\ []) when is_binary(repo) do
    list_scoped_issues(repo, "issues", opts)
  end

  # /issues supports assigned_by for both types on the measured Gitea 1.26.1 deployment.
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
  @spec assigned_by_qs(keyword()) :: String.t()
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
  Paginates issue comments in server order. Latest-marker readers assume oldest-first;
  this function does not sort, verify ordering or freeze the thread during pagination.
  """
  @spec list_comments(String.t(), integer(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      paginate(config, "/repos/#{encode_repo(repo)}/issues/#{number}/comments", "")
    end
  end

  @doc """
  Requests exactly [login] as assignees, skipping PATCH when the preceding read already matches.
  Success acknowledges the PATCH response without readback or protection against concurrent edits.
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
        config
        |> http_patch("/repos/#{encode_repo(repo)}/issues/#{issue_number}", %{assignees: [login]})
        |> acted(:set)
      end
    end
  end

  @doc """
  Posts unless :dedup_signature occurs in a trusted comment. Default trust is the resolved bot;
  :dedup_role adds that role's resolved login, while :dedup_any_author trusts every author.
  Failed bot/history reads log unverified dedup and post anyway; failed role resolution keeps
  bot-only trust. This is not atomic: concurrent calls or unreadable history can duplicate.
  """
  @spec post_comment(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :posted | :already} | {:error, term()}
  def post_comment(repo, issue_number, body, opts \\ [])
      when is_binary(body) do
    sig = Keyword.get(opts, :dedup_signature)

    with {:ok, config} <- resolve_config(opts) do
      if sig && Signing.signed_or_warn(config, repo, issue_number, sig, opts) do
        {:ok, :already}
      else
        config
        |> http_post("/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", %{body: body})
        |> acted(:posted)
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
         {:ok, current} <- Labels.get_issue_labels(config, repo, issue_number) do
      # Attached-label ids cover repository and organization labels.
      case Enum.find(current, &(&1["name"] == label_name)) do
        nil ->
          {:ok, :already_absent}

        %{"id" => id} ->
          config
          |> http_delete("/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels/#{id}")
          |> acted(:removed)
      end
    end
  end

  @doc """
  Starts native time tracking. Treats every HTTP 409 as an already-active success without readback.
  """
  @spec start_stopwatch(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def start_stopwatch(repo, number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{number}/stopwatch/start", nil) do
        {:ok, _} -> :ok
        {:error, {:http, 409, _}} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Stops native time tracking. Treats every HTTP 409 as an already-stopped success without readback.
  """
  @spec stop_stopwatch(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def stop_stopwatch(repo, number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{number}/stopwatch/stop", nil) do
        {:ok, _} -> :ok
        {:error, {:http, 409, _}} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  PATCHes state closed; :closure must be :delivered (stage/merged), :retired (stage/retired)
  or :marker (no stamp). The caller declares intent; this module does not prove delivery.
  Closed blockers release dependencies even when retired, so callers must handle their edges
  explicitly rather than infer delivery from closure or an absent label.

  Stamping and retired-lock removal follow the close. Returned failures are logged and do not
  undo closure; exceptions can still propagate after the PATCH. Delivered/marker closures do not
  remove in-flight locks here. Repeats PATCH again and retry the follow-up operations.
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
      lift_in_flight_on_retire(repo, issue_number, kind, opts)
      {:ok, :closed}
    end
  end

  # Report the requested act from HTTP success without inspecting its response body.
  defp acted({:ok, _}, verbe), do: {:ok, verbe}
  defp acted({:error, _} = err, _verbe), do: err

  defp merge_marker_number(comment) do
    case ForgeProtocol.parse_merge_marker(comment["body"] || "") do
      {:ok, n} -> n
      :error -> nil
    end
  end

  defp escalation_marker_body(comment) do
    body = is_map(comment) and comment["body"]
    if is_binary(body) and ForgeProtocol.escalation_marker?(body), do: body
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

  # A scoped stage stamp cannot evict the flat in-flight lock. Retirement may close active work;
  # the delivered seal instead relies on StepRunCompleter.unlock upstream. Failure here leaves
  # a stale lock on a closed ticket; retrying removal is a no-op once absent.
  defp lift_in_flight_on_retire(repo, n, :retired, opts) do
    case remove_label(repo, n, Fleet.Labels.in_flight(), opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ForgeClient: #{repo}##{n} retired but `#{Fleet.Labels.in_flight()}` NOT lifted " <>
            "(#{inspect(reason)}) — stale lock left on a closed ticket"
        )

        :ok
    end
  end

  defp lift_in_flight_on_retire(_repo, _n, _kind, _opts), do: :ok

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
  Paginates issues blocking number; dependency enforcement stays on the forge.
  On the measured deployment, a closed blocker satisfies the dependency even if retired
  without delivery. Closing does not remove or redirect its edges to replacement work.
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

  Body uses repo rather than IssueMeta's advertised name: tested on Gitea 1.26.1 (2026-08-04),
  where name yielded IsErrRepoNotExist. repo must split into owner/name or the call raises.
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

  DELETE carries the identifying body (index, owner, repo), as in add_issue_dependency/4.
  Retirement callers must also explain the removed dependency; deleting an edge does not deliver
  or replace its work. This function neither annotates the dependent nor redirects the edge.
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
  @spec list_org_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_org_repos(org, opts \\ []), do: Repo.list_org_repos(org, opts)

  @doc "Repos in a human's personal space — the deposit candidates (cf. `Repo.list_user_repos/2`)."
  @spec list_user_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_user_repos(login, opts \\ []), do: Repo.list_user_repos(login, opts)

  @doc "Whether a repo is PRIVATE on the forge (cf. `Repo.private?/2`)."
  @spec private?(String.t(), Keyword.t()) :: {:ok, boolean()} | {:error, term()}
  def private?(repo, opts \\ []), do: Repo.private?(repo, opts)

  @doc "Transfere un depot vers une autre org. Cf. `Fleet.Forge.Client.Repo.transfer_repo/3`."
  @spec transfer_repo(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transfer_repo(repo, new_owner, opts \\ []), do: Repo.transfer_repo(repo, new_owner, opts)

  @doc "Numeric forge id of the repo. See `Fleet.Forge.Client.Repo.repo_id/2`."
  @spec repo_id(String.t(), Keyword.t()) :: {:ok, integer()} | {:error, term()}
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
    with {:ok, config} <- resolve_config(opts),
         {:ok, pulls} <- paginate(config, "/repos/#{encode_repo(repo)}/pulls", "state=open") do
      case Enum.find(pulls, &pr_matches_head?(&1, head, base)) do
        %{"number" => number} -> {:ok, number}
        _ -> {:error, :pr_not_found}
      end
    end
  end

  defp pr_matches_head?(pr, head, base) do
    get_in(pr, ["head", "ref"]) == head and get_in(pr, ["base", "ref"]) == base
  end

  @doc """
  Traduit le repo_id du canal d'un pod en full_name pour les appels owner/name.
  Accepte une chaîne non vide sans valider sa forme ; réponse inattendue → unexpected_repo_shape,
  404 → repo_not_found. L'identité numérique reste celle utilisée pour séparer les slots par dépôt.
  """
  @spec repo_full_name(integer(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  def repo_full_name(repo_id, opts \\ []) when is_integer(repo_id) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/repositories/#{repo_id}") do
        {:ok, %{"full_name" => full}} when is_binary(full) and full != "" -> {:ok, full}
        {:ok, _} -> {:error, {:unexpected_repo_shape, repo_id}}
        {:error, {:http, 404, _}} -> {:error, :repo_not_found}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Renvoie %{head_sha, base_sha, head_ref, base_ref}. Les SHAs permettent à la sonde de viser
  des commits fixes plutôt que des branches mobiles. Leur présence est contrôlée, pas leurs types
  ni leur existence Git. Map incomplète → unexpected_pr_shape ; 404 → pr_not_found.
  Une réponse 2xx non-map n'a pas de clause de repli.
  """
  @spec pr_refs(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def pr_refs(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}") do
        {:ok, %{"head" => %{"sha" => hs, "ref" => hr}, "base" => %{"sha" => bs, "ref" => br}}} ->
          {:ok, %{head_sha: hs, head_ref: hr, base_sha: bs, base_ref: br}}

        # Missing keys are diagnosed; present nil values still match the preceding clause.
        {:ok, other} when is_map(other) ->
          {:error, {:unexpected_pr_shape, Map.keys(other)}}

        {:error, {:http, 404, _}} ->
          {:error, :pr_not_found}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Requests reviews for role names, projected to forge logins by RoleIdentity.login/1.
  Raw roles such as qualifier are not necessarily account names. One unresolved role refuses
  the entire POST, avoiding a partially requested jury; this does not verify reviewer acceptance.
  """
  @spec request_review(String.t(), integer(), [String.t()], Keyword.t()) ::
          :ok | {:error, term()}
  def request_review(repo, index, roles, opts \\ [])
      when is_binary(repo) and is_integer(index) and is_list(roles) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, logins} <- forge_logins(roles) do
      case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/requested_reviewers", %{
             reviewers: logins
           }) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp forge_logins(roles) do
    Enum.reduce_while(roles, {:ok, []}, fn role, {:ok, acc} ->
      case Fleet.Credentials.RoleIdentity.login(role) do
        {:ok, login} -> {:cont, {:ok, [login | acc]}}
        {:error, reason} -> {:halt, {:error, {:role_login_unresolved, role, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
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
  PATCHes PR state closed without merging. Retirement must handle PRs separately: review
  dispatch polls them independently of issue closure. This call does not close the issue,
  reap a pod or check whether the PR merged concurrently.
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
  Demande merge_when_checks_succeed, méthode par défaut rebase. :ok accuse la réponse HTTP,
  sans prouver une fusion future ou différée ; toutes les erreurs sont propagées.
  Ne lance pas le nettoyage de head de merge_pr/3, qui supprimerait une branche encore utile.
  L'appelant doit vérifier la protection avant l'armement : les conditions peuvent déjà être
  satisfaites sans approbation. request_toolchain porte la garde :toolchain_auto_merge.
  """
  @spec schedule_auto_merge(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def schedule_auto_merge(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/merge", %{
             "do" => Keyword.get(opts, :method, "rebase"),
             "merge_when_checks_succeed" => true
           }) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Merges with :method defaulting to rebase, allowing replay onto an advanced base rather than
  an FF-then-rebase cascade that can retrigger asynchronous mergeability checks. The seal uses
  merge for conflict-resolution commits whose resolution must survive; this wrapper does not
  choose that override or guarantee a successful/linear result.

  On HTTP 405, Merge first reads the PR: mergeable: false returns merge_blocked. Otherwise a
  message containing "try again later" permits up to three total attempts, with default 800 ms
  between them. Other errors propagate. These are attempt limits, not a total call deadline.
  After HTTP success, attempts a separately spaced head-branch deletion; returned cleanup
  failures only warn, while exceptions may propagate after the merge has already occurred.
  """
  @merge_checking_retries 3
  @spec merge_pr(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def merge_pr(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts) do
      method = Keyword.get(opts, :method, "rebase")
      delay = Keyword.get(opts, :merge_retry_delay_ms, 800)
      Merge.do_merge(config, repo, index, method, delay, @merge_checking_retries)
    end
  end

  @doc """
  Lists PR records under the optional forge-side assignee scope, state defaulting to open.

  Hybrid (Gitea 1.26.1): `/pulls` has NO `assigned_by` filter; only the issue-shaped list
  `/issues?type=pulls&assigned_by=…` carries it, so each filtered number is expanded with
  `get_pull/3`. Any failed expansion fails the whole read.
  """
  @spec list_open_pulls(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_pulls(repo, opts \\ []) when is_binary(repo) do
    with {:ok, pr_issues} <- list_scoped_issues(repo, "pulls", opts) do
      pr_issues |> Enum.map(& &1["number"]) |> fetch_pulls(repo, opts)
    end
  end

  # Expand issue-shaped rows for head/reviewer fields. Bound concurrency for the shared pool,
  # preserve listing order and discard all accumulated records on a returned failure.
  # No updated_at cache: its invalidation coverage would need evidence before routing uses it.
  defp fetch_pulls(numbers, repo, opts) do
    numbers
    |> Task.async_stream(&get_pull(repo, &1, opts),
      max_concurrency: 8,
      ordered: true,
      # Per-task timeout returns an exit tuple; this is not a deadline for the whole listing.
      # async_stream tasks are linked, so other task crashes can still exit the caller.
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
  Paginates /pulls with state=all and server-side base filtering for reconciliation drains.
  Unlike list_pulls/2, this endpoint supplies PR records without per-number expansion.
  """
  @spec list_pulls_for_base(String.t(), String.t(), Keyword.t()) ::
          {:ok, [map()]} | {:error, term()}
  def list_pulls_for_base(repo, base, opts \\ [])
      when is_binary(repo) and is_binary(base) do
    with {:ok, config} <- resolve_config(opts) do
      paginate(
        config,
        "/repos/#{encode_repo(repo)}/pulls",
        "state=all&base=" <> URI.encode_www_form(base)
      )
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
  Fetches the PR named by the last recognized [merge:pr-N] marker in server comment order.
  Markers survive deleted/rewritten head refs (see Protocol.merge_marker/1). No marker after
  successful pagination returns :none; fetch errors propagate. Author and PR merged state are
  not checked, so this observability read is not delivery proof or write authorization.
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
      |> Enum.find_value(&merge_marker_number/1)
      |> case do
        nil -> :none
        pr_number -> get_pull(repo, pr_number, opts)
      end
    end
  end

  @doc "Jury state (verdicts + jury SET + outcome) of a PR. See `Fleet.Forge.Client.Jury.pr_review_state/3`."
  @spec pr_review_state(String.t(), integer(), Keyword.t()) :: {:ok, term()} | {:error, term()}
  def pr_review_state(repo, index, opts \\ []), do: Jury.pr_review_state(repo, index, opts)

  @doc "Feedback of the REQUEST_CHANGES in force. See `Fleet.Forge.Client.Jury.change_request_feedback/3`."
  @spec change_request_feedback(String.t(), integer(), Keyword.t()) ::
          {:ok, term()} | {:error, term()}
  def change_request_feedback(repo, index, opts \\ []),
    do: Jury.change_request_feedback(repo, index, opts)

  @doc """
  Counts the largest same-base group of durable publish-failure markers for issue `n`.

  Groups all matching comments, regardless of author or adjacency, and takes the maximum.
  Interpreting this as a consecutive streak assumes each successful push advances the marker base.
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

  @doc "Counts the rework rounds. See `Fleet.Forge.Client.Jury.count_change_request_rounds/3`."
  @spec count_change_request_rounds(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_change_request_rounds(repo, index, opts \\ []),
    do: Jury.count_change_request_rounds(repo, index, opts)

  @doc """
  Reduces commit status history via CI: max integer id per context, then worst current status.
  If any id in a context is noninteger, all its statuses vote. Response order is not trusted;
  the Gitea 1.26.1 ordering observation is documented alongside CI.current_per_context/1.
  failure/error → failure; pending or unknown → pending; success/warning → success;
  skipped does not vote. No voting statuses returns none, distinct from a successful run.
  """
  @spec commit_ci_state(String.t(), String.t(), Keyword.t()) ::
          {:ok, :success | :pending | :failure | :none} | {:error, term()}
  def commit_ci_state(repo, sha, opts \\ []) when is_binary(repo) and is_binary(sha) do
    with {:ok, {state, _contexts}} <- commit_ci_report(repo, sha, opts), do: {:ok, state}
  end

  @doc """
  Returns the aggregate verdict plus sorted unique binary context names from the full response,
  including skipped contexts. Names explain which rails were reported; they do not prove a
  meaningful test harness ran. commit_ci_state/3 delegates here and discards the names.
  """
  @spec commit_ci_report(String.t(), String.t(), Keyword.t()) ::
          {:ok, {:success | :pending | :failure | :none, [String.t()]}} | {:error, term()}
  def commit_ci_report(repo, sha, opts \\ []) when is_binary(repo) and is_binary(sha) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, statuses} <-
           paginate(config, "/repos/#{encode_repo(repo)}/commits/#{encode_seg(sha)}/statuses", "") do
      contexts =
        statuses
        |> Enum.map(& &1["context"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, {statuses |> CI.current_per_context() |> CI.worst_ci_state(), contexts}}
    end
  end

  @doc """
  Contextes failure/error au plus grand id entier, avec description et target_url pour le brief.
  Un contexte sans nom binaire ou avec un id non entier est écarté : nommer le responsable
  demande un ordre établi, tandis que commit_ci_state/3 conserve le pire pour bloquer le merge.
  """
  @spec commit_ci_failures(String.t(), String.t(), Keyword.t()) ::
          {:ok,
           [%{context: String.t(), description: String.t() | nil, target_url: String.t() | nil}]}
          | {:error, term()}
  def commit_ci_failures(repo, sha, opts \\ []) when is_binary(repo) and is_binary(sha) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, statuses} <-
           paginate(config, "/repos/#{encode_repo(repo)}/commits/#{encode_seg(sha)}/statuses", "") do
      {:ok, CI.red_contexts(statuses)}
    end
  end

  @doc "Judges re-requested after judgment (timeline). See `Fleet.Forge.Client.Jury.pr_rerequested_reviewers/3`."
  @spec pr_rerequested_reviewers(String.t(), integer(), Keyword.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def pr_rerequested_reviewers(repo, index, opts \\ []),
    do: Jury.pr_rerequested_reviewers(repo, index, opts)

  @stage_prefix Fleet.Labels.stage_prefix()
  @wfmap_prefix Fleet.Labels.wfmap_prefix()

  @doc """
  Adds wfmap/<pipeline>, then stage/<step>. The calls are non-atomic; stage failure can leave
  the map applied. Scoped-label exclusivity is delegated to the forge, not checked locally.
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
  Adds stage/<stage> without writing workflow-map labels. Relies on forge scoped-label exclusivity.
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
         {:ok, labels} <- Labels.get_issue_labels(config, repo, issue_number) do
      route_from_labels(labels)
    end
  end

  @doc """
  Dérive sans I/O la route depuis des maps name ou des noms binaires, pour réutiliser les labels
  déjà lus par Poller.Lease. get_route/3 partage cette règle après sa propre lecture HTTP.
  Premier préfixe wfmap et premier préfixe stage gagnent ; valeurs vides acceptées, autres entrées
  ignorées. Ne valide ni unicité, ni carte/étape existante, ni auteur des labels.
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
  Résout le compte qui détient le jeton frais du rôle, via Transport.login_of/1 (/user), sans
  les surcharges du login système. Nécessaire pour vérifier l'auteur réel des marqueurs de rôle.
  Le cache garde un couple empreinte/login par base_url : changer de jeton remplace l'entrée,
  donc alterner les rôles peut relancer /user. La demande de jeton a lieu même sur cache hit.
  """
  @spec role_login(String.t(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  def role_login(role, opts \\ []) when is_binary(role) do
    with {:ok, role_opts} <- as_role(opts, role),
         {:ok, config} <- resolve_config(role_opts) do
      login_of(config)
    end
  end

  # Author equality authenticates one marker-bearing comment, not each marker occurrence.
  defp count_signed(c, {:ok, n}, bot, opts) do
    role = ForgeProtocol.step_run_marker_role(c["body"])
    author = get_in(c, ["user", "login"])

    if author == bot do
      {:cont, {:ok, n + 1}}
    else
      case role_login(role, opts) do
        {:ok, ^author} ->
          {:cont, {:ok, n + 1}}

        {:ok, _other} ->
          {:cont, {:ok, n}}

        # Unavailable credentials skip this comment, including authority failures normalized
        # by RoleIdentity. This does not prove the role or its historical token never existed.
        {:error, :role_token_unavailable} ->
          {:cont, {:ok, n}}

        # Other returned errors (e.g. /user unreadable) abort the count.
        {:error, reason} ->
          {:halt, {:error, {:role_login_unresolved, role, reason}}}
      end
    end
  end

  @doc """
  Counts comments carrying a recognized step-run marker for the anti-runaway budget, once per
  comment without deduplicating repeated posts. Trusts the resolved bot or the account of the
  first recognized marker's role. Missing role credentials skip that comment; other returned
  identity/history errors abort. Author equality is the check, not cryptographic body signing.
  """
  @spec count_signed_step_runs(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_signed_step_runs(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      comments
      |> Enum.filter(&(ForgeProtocol.step_run_marker_role(&1["body"]) != nil))
      |> Enum.reduce_while({:ok, 0}, &count_signed(&1, &2, bot, opts))
    end
  end

  @doc """
  Last escalation-marked body in server comment order, for the arch inbox. Protocol owns the
  format; the MCP seam asks this client rather than reaching into Pilot. No author filtering.
  Successful read without a marker returns {:ok, nil}: the recurrence brake may set awaits-arch
  without a comment. Returning arbitrary recent prose could hand the arch its own previous answer.
  """
  @spec escalation_verdict(String.t(), integer(), Keyword.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def escalation_verdict(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      body =
        comments
        |> Enum.reverse()
        |> Enum.find_value(&escalation_marker_body/1)

      {:ok, body}
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

  @doc """
  Attempts static lock, destination, stage and visual-type label creation/color reconciliation,
  then verifies names via readback. Success does not certify color or description convergence.
  Missing/unreadable labels return labels_missing/labels_unverifiable; dynamic wfmap labels
  are not seeded. Earlier changes are not rolled back on failure.
  """

  # Read protocol names from Fleet.Labels so renames also reach seeding.

  @spec ensure_protocol_labels(String.t(), keyword()) :: :ok | {:error, term()}
  def ensure_protocol_labels(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts) do
      statics =
        [
          Fleet.Labels.in_flight(),
          Fleet.Labels.awaits_arch(),
          # Seed the project-face destination used at issue creation.
          Fleet.Labels.destination_workshop(),
          # Workflow step names are data, not protocol constants; other steps are created on demand.
          "stage/brief-review",
          "stage/build",
          Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_review(),
          Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_merged(),
          # Preseed retired for its operator-facing palette as well as on-demand routing use.
          Fleet.Labels.stage_prefix() <> Fleet.Labels.stage_retired()
        ] ++ Fleet.Labels.visual_types()

      Enum.each(statics, &Labels.ensure_repo_label(config, repo, &1))
      Labels.verify_labels_present(config, repo, statics)
    end
  end

  @doc """
  Replaces :token with the role's freshly resolved token, retaining other options. Transport's
  token precedence makes it win over retained token_file/account fields. Unavailable/invalid role
  credentials return role_token_unavailable without using the caller's privileged token.
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
