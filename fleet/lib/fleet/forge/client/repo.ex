defmodule Fleet.Forge.Client.Repo do
  @moduledoc """
  **Repo provisioning** in the agent machine — sub-domain of `Fleet.Forge.Client`:
  repo creation, discovery by org-membership (WS3), branch-protection, the repo's forge
  identity. (Admission is org membership, managed UPSTREAM by the human admin — no
  server-side admission marker, no mutable topic, no collaborator management here.)

  The *seam-faced* ops (`repo_id`, `list_org_repos`) are forwarded by `ForgeClient` (the module injected
  by the `:forge_client` seam stays it); the provisioning ops (`create_repo`, `protect_branch`)
  are called directly by `Fleet.Project.Onboard`.
  """

  import Fleet.Forge.Client.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_patch: 3,
      http_delete: 2,
      paginate: 3
    ]

  import Fleet.Forge.Client.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  @doc """
  Creates an organization or token-owned repository, initialized on `main` by default.

  Returns `{:ok, :already_exists}` on conflict so provisioning is replayable.
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
  Generates a fresh repository from a native forge template, copying content, labels, and topics
  (native scaffolding, VERIFIED live on this forge 2026-07-18): git content copied with
  but not branch protection. Returns `:template_missing` on 404 and `:already_exists` on 409.
  """
  @spec generate_repo(String.t(), String.t(), keyword()) ::
          {:ok, String.t() | :already_exists} | {:error, term()}
  def generate_repo(template_repo, name, opts \\ [])
      when is_binary(template_repo) and is_binary(name) do
    with {:ok, config} <- resolve_config(opts) do
      body = %{
        owner: Keyword.get(opts, :org, "fleet"),
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
  Marks or unmarks a repository as a native forge template.
  """
  @spec set_template(String.t(), boolean(), keyword()) :: :ok | {:error, term()}
  def set_template(repo, template?, opts \\ []) when is_binary(repo) and is_boolean(template?) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <- http_patch(config, "/repos/#{encode_repo(repo)}", %{template: template?}) do
      :ok
    end
  end

  @doc """
  Returns every repository full name in an organization, using fail-loud pagination.
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
  Returns the repository's default branch. Import callers currently require it to be `main`.
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
  Returns a branch tip SHA for the seal's provenance check.
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
  Reports whether a branch can be read. Any error returns `false`; subsequent creation remains the
  forge's authority and cannot overwrite an existing branch.
  """
  @spec branch_exists?(String.t(), String.t(), Keyword.t()) :: boolean()
  def branch_exists?(repo, branch, opts \\ []) when is_binary(repo) and is_binary(branch) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_get(config, "/repos/#{encode_repo(repo)}/branches/#{encode_seg(branch)}") do
      true
    else
      _ -> false
    end
  end

  @doc """
  Distinguishes a proven missing account (`{:ok, false}`) from a forge failure.
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
  Checks team membership with the same proven-absence/error distinction as `user_exists?/2`.

  A missing team is a proven negative membership result. Team discovery is fully paginated.
  """
  @spec team_member?(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, boolean()} | {:error, term()}
  def team_member?(org, team, username, opts \\ [])
      when is_binary(org) and is_binary(team) and is_binary(username) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, teams} <- paginated_teams(config, org) do
      case Enum.find(teams, &(is_map(&1) and &1["name"] == team)) do
        nil ->
          {:ok, false}

        %{"id" => id} ->
          case http_get(config, "/teams/#{id}/members/#{encode_seg(username)}") do
            {:ok, _} -> {:ok, true}
            {:error, {:http, 404, _}} -> {:ok, false}
            {:error, _} = err -> err
          end
      end
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
  Converges a forge-enforced branch-protection rule and reports `:created`, `:updated`, or
  `:unchanged`.

  Existing-rule detection requires the forge's precise message across status variants. Readback and
  patch compare only caller-projected fields; permission and invalid-rule errors remain failures.
  """
  @type protection_outcome :: :created | :updated | :unchanged

  @spec protect_branch(String.t(), map(), Keyword.t()) ::
          {:ok, protection_outcome()} | {:error, term()}
  def protect_branch(repo, rule, opts \\ []) when is_binary(repo) and is_map(rule) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/branch_protections", rule) do
        {:ok, _} ->
          {:ok, :created}

        {:error, {:http, code, %{"message" => msg}}}
        when code in [403, 409, 422] and is_binary(msg) ->
          if String.contains?(msg, "already exist"),
            do: converge_existing_protection(config, repo, rule),
            else: {:error, {:http, code, %{"message" => msg}}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp converge_existing_protection(config, repo, rule) do
    rule_name = Map.fetch!(rule, :rule_name)
    path = "/repos/#{encode_repo(repo)}/branch_protections/#{encode_seg(rule_name)}"
    projected = projected_protection_fields(rule)

    if projected == %{} do
      {:ok, :unchanged}
    else
      case http_get(config, path) do
        {:ok, existing} when is_map(existing) ->
          if Map.take(existing, Map.keys(projected)) == projected do
            {:ok, :unchanged}
          else
            case http_patch(config, path, projected) do
              {:ok, _} -> {:ok, :updated}
              {:error, reason} -> {:error, {:protection_reconcile_failed, reason}}
            end
          end

        {:ok, other} ->
          {:error, {:protection_readback_invalid, other}}

        {:error, reason} ->
          {:error, {:protection_readback_failed, reason}}
      end
    end
  end

  # The reconcilable surface = the protection fields the runtime projects, restricted to those
  # the CALLER actually projected (string keys, the wire's shape on readback). Comparing or
  # patching MORE would clobber operator enrichments (status checks) the runtime never
  # projected. The push-door fields (`enable_push*`, `push_whitelist_usernames`) are projected
  # ONLY by the card-revision lift (`ProjectOnboard.revise_card` — scoped lift-push-restore);
  # the canonical `protect_main` rule does not name them, so an operator whitelist stays
  # untouched outside that one deliberate gesture.
  # `enable_status_check`/`status_check_contexts` ARE projected (2026-08-03). The comment above used
  # to name status checks as the example of an "operator enrichment" the runtime must not clobber —
  # a posture that assumed an operator who never came: measured on a live bench, every repo had
  # `enable_status_check: false` and a red CI merged. An enrichment nobody applies is not an
  # enrichment, it is a hole with a polite name.
  @protectable_fields ~w(required_approvals dismiss_stale_approvals block_on_rejected_reviews enable_push enable_push_whitelist push_whitelist_usernames enable_status_check status_check_contexts)

  defp projected_protection_fields(rule) do
    for {k, v} <- rule, sk = to_string(k), sk in @protectable_fields, into: %{}, do: {sk, v}
  end

  @doc """
  Transfers `repo` (`"owner/name"`) to `new_owner`, and returns its new full name.

  Mesure sur une forge de banc (Gitea 1.26) : `202`, et TOUT survit — issues, PR, labels,
  protection de branche, attribution des commentaires ; l'ancienne URL rend un `301`. Ce qui ne
  suit PAS est ce qu'on ne veut pas voir suivre : les droits ne se transferent pas, ils se
  REDERIVENT des teams de l'org d'arrivee.

  Le `202` est un ACCEPTE, pas un fait accompli : Gitea accepte aussi un transfert qui restera
  PENDING si la cible doit l'approuver. Entre orgs dont on possede les deux, il est immediat — et
  le lecteur qui compte dessus est le repointage local, qui suit dans le meme geste.
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
