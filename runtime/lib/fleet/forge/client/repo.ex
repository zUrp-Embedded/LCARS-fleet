defmodule Fleet.Forge.Client.Repo do
  @moduledoc """
  Repository provisioning, discovery, identity and branch protection.
  Admission membership is managed upstream by the human admin; this module reads it.
  `Fleet.Forge.Client` forwards seam operations such as `repo_id` and `list_org_repos`;
  `Fleet.Project.Onboard` calls provisioning operations directly.
  """

  import Fleet.Forge.Client.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_patch: 3,
      http_delete: 2,
      paginate: 3,
      paginate: 4
    ]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  @doc """
  Creates an organization or token-owned repository, initialized on `main` by default.

  Any HTTP 409 returns `{:ok, :already_exists}` without checking the existing configuration.
  """
  @spec create_repo(String.t(), Keyword.t()) ::
          {:ok, String.t() | :already_exists} | {:error, term()}
  def create_repo(name, opts \\ []) when is_binary(name) do
    with {:ok, config} <- resolve_config(opts) do
      body = %{
        name: name,
        description: Keyword.get(opts, :description, ""),
        private: Keyword.get(opts, :private, false),
        auto_init: Keyword.get(opts, :auto_init, true),
        default_branch: Keyword.get(opts, :default_branch, "main")
      }

      path =
        case Keyword.get(opts, :org) do
          org when is_binary(org) and org != "" -> "/orgs/#{encode_seg(org)}/repos"
          _ -> "/user/repos"
        end

      case http_post(config, path, body) do
        {:ok, %{"full_name" => full_name}} -> {:ok, full_name}
        {:error, {:http, 409, _}} -> {:ok, :already_exists}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Requests template generation with git content, labels and topics; `opts[:org]` names the owner
  and is required (a catalogue names the org of its projects; this client has no default).
  The 2026-07-18 forge bench copied those fields but not branch protection.
  Maps HTTP 404 to `:template_missing`, 409 to `:already_exists`, without checking existing state.
  """
  @spec generate_repo(String.t(), String.t(), keyword()) ::
          {:ok, String.t() | :already_exists} | {:error, term()}
  def generate_repo(template_repo, name, opts \\ [])
      when is_binary(template_repo) and is_binary(name) do
    with {:ok, config} <- resolve_config(opts) do
      body = %{
        # No default owner: the caller names the org, a catalogue does (Forge cannot read Catalogue).
        owner: Keyword.fetch!(opts, :org),
        name: name,
        description: Keyword.get(opts, :description, ""),
        private: Keyword.get(opts, :private, false),
        git_content: true,
        labels: true,
        topics: true
      }

      case http_post(config, "/repos/#{encode_repo(template_repo)}/generate", body) do
        {:ok, %{"full_name" => full_name}} -> {:ok, full_name}
        {:error, {:http, 404, _}} -> {:error, :template_missing}
        {:error, {:http, 409, _}} -> {:ok, :already_exists}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Sets the template flag; HTTP success is accepted without readback.
  """
  @spec set_template(String.t(), boolean(), keyword()) :: :ok | {:error, term()}
  def set_template(repo, template?, opts \\ []) when is_binary(repo) and is_boolean(template?) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <- http_patch(config, "/repos/#{encode_repo(repo)}", %{template: template?}) do
      :ok
    end
  end

  @doc """
  Paginates organization repositories and extracts full_name, dropping nil values only.
  Visibility comes from the forge response; names and individual entries are not validated.
  """
  @spec list_org_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_org_repos(org, opts \\ []) when is_binary(org) do
    # DR-016
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} <- paginate(config, "/orgs/#{encode_seg(org)}/repos", "") do
      {:ok, body |> Enum.map(&Map.get(&1, "full_name")) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  Paginates a user's repositories, extracting full_name and dropping nil values only.
  Personal-space deposits are candidates; enrolled projects live in the catalogue organization.
  On the 2026-08-11 bench the system token's read:user scope succeeded, while a role token
  with write:issue/write:repository received 403 for the missing scope.
  """
  @spec list_user_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_user_repos(login, opts \\ []) when is_binary(login) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} <- paginate(config, "/users/#{encode_seg(login)}/repos", "") do
      {:ok, body |> Enum.map(&Map.get(&1, "full_name")) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  Paginates `/repos/search`, unwraps `data` and keeps map entries (without checking `ok`).
  On Gitea 1.26, 2026-08-16, the system token found admiral/sonde-depot here but not in
  `/user/repos`; making that deposit private removed it from these search results.
  Discovery relies on server visibility, with no local filter excluding all private repositories.
  """
  @spec search_repos(Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def search_repos(opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} <- paginate(config, "/repos/search", "", "data") do
      {:ok, Enum.filter(body, &is_map/1)}
    end
  end

  @doc """
  Returns `%{sha, message}` for callers tracking a catalogue projection's source.
  The store is a fresh commit, so different HEADs need not mean different content.
  On the 2026-08-16 Gitea 1.26.1 bench, `/git/trees/{sha}` echoed the input SHA and
  `/git/commits/{sha}` reported the commit SHA as tree.sha; neither supplied the needed tree hash.
  `push_store` therefore writes `Source-Commit:` in the message. Parsing that trailer and
  treating its absence as unknown belong to the caller; this function returns the raw message.
  A missing message defaults to "", but present values are unchecked. HTTP 404 becomes :not_found.
  """
  @spec branch_commit(String.t(), String.t(), Keyword.t()) ::
          {:ok, %{sha: String.t(), message: String.t()}} | {:error, term()}
  def branch_commit(repo, branch, opts \\ []) when is_binary(repo) and is_binary(branch) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/repos/#{encode_repo(repo)}/branches/#{encode_seg(branch)}") do
        {:ok, %{"commit" => %{"id" => sha} = c}} when is_binary(sha) ->
          {:ok, %{sha: sha, message: Map.get(c, "message", "")}}

        {:ok, _} ->
          {:error, :no_branch_sha}

        {:error, {:http, 404, _}} ->
          {:error, :not_found}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Returns a binary default branch, including an empty string; no main-branch policy is enforced here.
  """
  @spec default_branch(String.t(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  def default_branch(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, %{"default_branch" => b}} when is_binary(b) <-
           http_get(config, "/repos/#{encode_repo(repo)}") do
      {:ok, b}
    else
      {:ok, _} -> {:error, :no_default_branch}
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns a binary branch tip for the seal's provenance check, without SHA format validation.
  Unlike branch_commit/3, HTTP 404 retains the transport error shape.
  """
  @spec branch_head(String.t(), String.t(), Keyword.t()) :: {:ok, String.t()} | {:error, term()}
  def branch_head(repo, branch, opts \\ []) when is_binary(repo) and is_binary(branch) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, %{"commit" => %{"id" => sha}}} when is_binary(sha) <-
           http_get(config, "/repos/#{encode_repo(repo)}/branches/#{encode_seg(branch)}") do
      {:ok, sha}
    else
      {:error, _} = err -> err
      other -> {:error, {:branch_head_unexpected, other}}
    end
  end

  @doc """
  HTTP success => true, HTTP 404 => false; other errors propagate.
  Callers use this distinction for protection, import and publication decisions.
  It classifies the response, without validating its body or distinguishing a masked 404.
  """
  @spec branch_exists?(String.t(), String.t(), Keyword.t()) ::
          {:ok, boolean()} | {:error, term()}
  def branch_exists?(repo, branch, opts \\ []) when is_binary(repo) and is_binary(branch) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/repos/#{encode_repo(repo)}/branches/#{encode_seg(branch)}") do
        {:ok, _} -> {:ok, true}
        {:error, {:http, 404, _}} -> {:ok, false}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  HTTP success => :deleted, HTTP 404 => :absent, without readback.
  Other errors propagate so compensation callers can report an unsuccessful cleanup.
  """
  @spec delete_branch(String.t(), String.t(), Keyword.t()) ::
          {:ok, :deleted | :absent} | {:error, term()}
  def delete_branch(repo, branch, opts \\ []) when is_binary(repo) and is_binary(branch) do
    with {:ok, config} <- resolve_config(opts) do
      case http_delete(config, "/repos/#{encode_repo(repo)}/branches/#{encode_seg(branch)}") do
        {:ok, _} -> {:ok, :deleted}
        {:error, {:http, 404, _}} -> {:ok, :absent}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  HTTP success => true, HTTP 404 => false; other errors propagate.
  """
  @spec user_exists?(String.t(), Keyword.t()) :: {:ok, boolean()} | {:error, term()}
  def user_exists?(username, opts \\ []) when is_binary(username) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/users/#{encode_seg(username)}") do
        {:ok, _} -> {:ok, true}
        {:error, {:http, 404, _}} -> {:ok, false}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Tests `/orgs/{name}` with the same HTTP mapping as user_exists?/2.
  `/users/{name}` could also match a personal account, which cannot stand for a catalogue org.
  Organization existence alone does not verify all catalogue provisioning.
  """
  @spec org_exists?(String.t(), Keyword.t()) :: {:ok, boolean()} | {:error, term()}
  def org_exists?(org, opts \\ []) when is_binary(org) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/orgs/#{encode_seg(org)}") do
        {:ok, _} -> {:ok, true}
        {:error, {:http, 404, _}} -> {:ok, false}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Paginates teams and selects the first matching name, then maps membership HTTP status
  as user_exists?/2 does. No matching team returns false; a matching team must carry an id.
  """
  @spec team_member?(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, boolean()} | {:error, term()}
  def team_member?(org, team, username, opts \\ [])
      when is_binary(org) and is_binary(team) and is_binary(username) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, teams} <- paginated_teams(config, org) do
      teams
      |> Enum.find(&(is_map(&1) and &1["name"] == team))
      |> member_of_team(config, username)
    end
  end

  defp member_of_team(nil, _config, _username), do: {:ok, false}

  defp member_of_team(%{"id" => id}, config, username) do
    case http_get(config, "/teams/#{id}/members/#{encode_seg(username)}") do
      {:ok, _} -> {:ok, true}
      {:error, {:http, 404, _}} -> {:ok, false}
      {:error, _} = err -> err
    end
  end

  defp paginated_teams(config, org) do
    case paginate(config, "/orgs/#{encode_seg(org)}/teams", "") do
      {:ok, teams} ->
        {:ok, teams}

      {:error, {:unexpected_page_shape, _p, _page, body}} ->
        {:error, {:unexpected_teams_shape, body}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Returns the repository's numeric forge identity; it is never synthesized on failure.
  """
  @spec repo_id(String.t(), Keyword.t()) :: {:ok, integer()} | {:error, term()}
  def repo_id(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, %{"id" => id}} when is_integer(id) <-
           http_get(config, "/repos/#{encode_repo(repo)}") do
      {:ok, id}
    else
      {:ok, _} -> {:error, :no_id}
      {:error, _} = err -> err
    end
  end

  @doc """
  Compares a map response's private field to literal true. Missing/other values give false;
  a successful non-map response passes through unchanged despite the spec.
  Adoption asks explicitly because a successful clone with system credentials need not mean public.
  """
  @spec private?(String.t(), Keyword.t()) :: {:ok, boolean()} | {:error, term()}
  def private?(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} when is_map(body) <- http_get(config, "/repos/#{encode_repo(repo)}") do
      {:ok, Map.get(body, "private") == true}
    end
  end

  @doc """
  Creates a protection rule or reconciles an existing one. HTTP 403/409/422 with the
  case-sensitive substring "already exist" triggers reconciliation; other errors propagate.
  That path requires atom :rule_name and compares only whitelisted fields supplied by the caller.
  An empty projection returns :unchanged without reading; successful POST/PATCH has no readback.
  """
  @type protection_outcome :: :created | :updated | :unchanged

  @spec protect_branch(String.t(), map(), Keyword.t()) ::
          {:ok, protection_outcome()} | {:error, term()}
  def protect_branch(repo, rule, opts \\ []) when is_binary(repo) and is_map(rule) do
    with {:ok, config} <- resolve_config(opts) do
      config
      |> http_post("/repos/#{encode_repo(repo)}/branch_protections", rule)
      |> protection_outcome(config, repo, rule)
    end
  end

  defp protection_outcome({:ok, _}, _config, _repo, _rule), do: {:ok, :created}

  defp protection_outcome(
         {:error, {:http, code, %{"message" => msg}}} = err,
         config,
         repo,
         rule
       )
       when code in [403, 409, 422] and is_binary(msg) do
    if String.contains?(msg, "already exist"),
      do: converge_existing_protection(config, repo, rule),
      else: err
  end

  defp protection_outcome({:error, _} = err, _config, _repo, _rule), do: err

  defp converge_existing_protection(config, repo, rule) do
    rule_name = Map.fetch!(rule, :rule_name)
    path = "/repos/#{encode_repo(repo)}/branch_protections/#{encode_seg(rule_name)}"
    projected = projected_protection_fields(rule)

    if projected == %{} do
      {:ok, :unchanged}
    else
      case http_get(config, path) do
        {:ok, existing} when is_map(existing) ->
          converge_protection(config, path, projected, existing)

        {:ok, other} ->
          {:error, {:protection_readback_invalid, other}}

        {:error, reason} ->
          {:error, {:protection_readback_failed, reason}}
      end
    end
  end

  # Ignore extra server fields to avoid patching every time or overwriting operator additions.
  defp converge_protection(config, path, projected, existing) do
    if Map.take(existing, Map.keys(projected)) == projected do
      {:ok, :unchanged}
    else
      case http_patch(config, path, projected) do
        {:ok, _} -> {:ok, :updated}
        {:error, reason} -> {:error, {:protection_reconcile_failed, reason}}
      end
    end
  end

  # Caller-supplied keys only, stringified for wire comparison. Push whitelist fields support
  # revise_card's lift/push/restore without changing them when protect_main omits them.
  # Status-check fields are owned too: the 2026-08-03 bench merged red CI with checks disabled.
  @protectable_fields ~w(required_approvals dismiss_stale_approvals block_on_rejected_reviews enable_push enable_push_whitelist push_whitelist_usernames enable_status_check status_check_contexts)

  defp projected_protection_fields(rule) do
    for {k, v} <- rule, sk = to_string(k), sk in @protectable_fields, into: %{}, do: {sk, v}
  end

  @doc """
  Requests transfer and returns full_name, or constructs new_owner/name if the response omits it.
  HTTP success (including 202) does not prove completion: target approval may leave it pending.
  A Gitea 1.26 bench preserved issues, PRs, labels, protection and comment attribution, redirected
  the old URL with 301 and derived permissions from destination teams. This function verifies none
  of those effects; callers repointing locally must account for transfer state.
  """
  @spec transfer_repo(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transfer_repo(repo, new_owner, opts \\ [])
      when is_binary(repo) and is_binary(new_owner) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/transfer", %{new_owner: new_owner}) do
        {:ok, %{"full_name" => full_name}} -> {:ok, full_name}
        {:ok, _} -> {:ok, "#{new_owner}/#{Fleet.Layout.project_name(repo)}"}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Deletes a repository. A missing repository succeeds; callers own confirmation policy.
  """
  @spec delete_repo(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_repo(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts) do
      case http_delete(config, "/repos/#{encode_repo(repo)}") do
        {:ok, _} -> :ok
        {:error, {:http, 404, _}} -> :ok
        {:error, _} = err -> err
      end
    end
  end
end
