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
      paginate: 3,
      paginate: 4
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
  Every repository full name in a HUMAN's personal space (`<login>/<name>`).

  The counterpart of `list_org_repos/2` for the other half of the model: a DEPOSITED project lives
  in its author's personal space, an ENROLLED one lives in its catalogue's org, and the LOCATION is
  the state. Listing the former is listing the candidates.

  The system token suffices — measured 2026-08-11: it carries `read:user`, so `200`. A ROLE token
  does not (`write:issue,write:repository`) and gets a `403` that NAMES the missing scope. Gitea
  tokens REPLACE permissions instead of adding to them: the scope is the question, not the account.
  """
  @spec list_user_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_user_repos(login, opts \\ []) when is_binary(login) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} <- paginate(config, "/users/#{encode_seg(login)}/repos", "") do
      {:ok, body |> Enum.map(&Map.get(&1, "full_name")) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  EVERY repository this token can SEE, across the whole forge — orgs and personal spaces alike.

  ## Why `/repos/search` and not `/user/repos`

  Measured 2026-08-16 on Gitea 1.26, with the SYSTEM token, against a deposit sitting in the
  master's personal space:

      /user/repos     -> fleet/lcars fleet/project-template fleet/ticket-drill
      /repos/search   -> fleet/lcars fleet/project-template admiral/sonde-depot fleet/ticket-drill

  `/user/repos` answers "what this account owns or has access to", which is the wrong question: a
  deposit in someone ELSE's personal space is neither. `/repos/search` answers "what is visible",
  which is the one that matches the model — a deposited catalogue lives in its author's space and
  the LOCATION is the state.

  ## What a PRIVATE deposit costs us: nothing

  Same measurement, after flipping that repo to private: it vanishes from `/repos/search`. Gitea
  enforces the rule on its own, so there is no visibility code here and none is wanted — an
  invisible deposit is invisible, and its absence from the list IS the message to its owner.

  The page arrives in an envelope (`%{"ok" => true, "data" => [...]}`), unlike every other list
  endpoint; the pagination is the shared one, told which key to take.
  """
  @spec search_repos(Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def search_repos(opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} <- paginate(config, "/repos/search", "", "data") do
      {:ok, Enum.filter(body, &is_map/1)}
    end
  end

  @doc """
  The HEAD of a branch as `%{sha, message}` — the sha, plus what the commit SAYS about itself.

  ## `branch_head/3` already answers the sha, and this does not replace it

  It exists next to it because two callers ask two different questions of the same endpoint: the
  seal wants the tip of a branch it is about to merge, this wants to know whether a catalogue's
  source has moved. Merging them would make the seal carry a message it never reads.

  ## Why the message is load-bearing here, and a sha alone is not

  A catalogue's store (`<name>/_catalogue`) is a PROJECTION of its deposit: a fresh single commit
  reflecting the deposit's tree. Two commits of identical content therefore never share a sha, so
  comparing the two HEADs answers "different commit", which is always true, rather than "the source
  moved", which is the question. Measured on a bench 2026-08-16: a catalogue installed thirty
  seconds earlier reported UPDATABLE.

  Nor does the forge hand out a content hash to compare instead. Gitea's `/git/trees/{sha}` echoes
  back the sha it was given rather than resolving the tree object, and `/git/commits/{sha}` reports
  `commit.tree.sha` equal to the commit sha — both measured on 1.26.1.

  So the projection CARRIES what it projects: `push_store` writes a `Source-Commit:` trailer, and
  this is what reads it back. Coupling to a message format is a real cost, and it is bounded — the
  message is ours, written by our gesture, read by our code, and a missing trailer answers "unknown"
  rather than "current".
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
  Distingue une branche PROUVEE absente (`{:ok, false}`) d'une forge qu'on n'a pas su lire.

  ⚠ JAMAIS `false` DANS LES DEUX CAS : ses trois appelants en tirent trois decisions DIFFERENTES,
  et aucune n'est sure sous cette confusion — une protection de branche silencieusement sautee, un
  import declare satisfait, une face republiee par-dessus une existante. Meme distinction que
  `user_exists?/2` : le 404 est une REPONSE de la forge, tout le reste est une absence de reponse.
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
  Deletes a branch, reporting `:deleted` or `:absent` — never conflating either with a failure.

  A 404 SATISFIES a caller that asked for the branch to be gone, so it is a success and not an
  error. Everything else is reported: this primitive exists to UNDO a mutation, and a compensation
  that cannot prove it removed what it created must never be announced as clean.
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
  Whether the ORGANISATION exists — the forge-side signature that a catalogue is INSTALLED.

  Same proven-absence/error distinction as `user_exists?/2`, and the distinction is the point: an
  org that is PROVEN missing (`{:ok, false}`) is a catalogue nobody provisioned, while a forge that
  is merely unreachable (`{:error, _}`) says nothing about it. Collapsing the two would either
  refuse a legitimate catalogue during an outage, or admit an unprovisioned one when the forge
  coughs.

  ⚠ `/orgs/{name}` and NOT `/users/{name}`, though Gitea would answer both. An org is a row of the
  same `user` table (`type = Organization`), so a PERSONAL account named `web` makes
  `/users/web` return 200 while no org `web` exists — and it is the org that carries a catalogue's
  projects and role accounts. Asking the wrong endpoint would sign an installation that is not one.
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
  Checks team membership with the same proven-absence/error distinction as `user_exists?/2`.

  A missing team is a proven negative membership result. Team discovery is fully paginated.
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

  # UNE EQUIPE QUI N'EXISTE PAS N'EST PAS UNE ERREUR DE LECTURE : personne n'en est membre, et la
  # reponse est aussi ferme que le 404 d'en dessous. C'est le `{:error, _}` qui remonte, lui, parce
  # que « je n'ai pas su demander » ne vaut pas « non ».
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
  Whether a repository is PRIVATE on the forge.

  Asked before adopting a deposit, and asked EXPLICITLY rather than inferred from a clone failing:
  the system token can read a private repo, so a clone would succeed and quietly copy private
  content into a public org repo. A visibility change nobody asked for is worse than a refusal,
  and it is invisible at the moment it happens.
  """
  @spec private?(String.t(), Keyword.t()) :: {:ok, boolean()} | {:error, term()}
  def private?(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} when is_map(body) <- http_get(config, "/repos/#{encode_repo(repo)}") do
      {:ok, Map.get(body, "private") == true}
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
      config
      |> http_post("/repos/#{encode_repo(repo)}/branch_protections", rule)
      |> protection_outcome(config, repo, rule)
    end
  end

  defp protection_outcome({:ok, _}, _config, _repo, _rule), do: {:ok, :created}

  # LA FORGE REFUSE UNE REGLE DEJA POSEE AVEC TROIS CODES DIFFERENTS selon la version, et le seul
  # discriminant stable est le texte. Un « existe deja » est le chemin nominal d'un re-onboarding :
  # on converge. Tout autre refus sous les memes codes reste une erreur.
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

  # L'etat DESIRE est deja la, ou il ne l'est pas. On compare sur les seules clefs projetees : la
  # forge en rend d'autres, et exiger l'egalite complete ferait patcher a chaque tour.
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

  # The reconcilable surface = the protection fields the runtime projects, restricted to those
  # the CALLER actually projected (string keys, the wire's shape on readback). Comparing or
  # patching MORE would clobber operator enrichments (status checks) the runtime never
  # projected. The push-door fields (`enable_push*`, `push_whitelist_usernames`) are projected
  # ONLY by the card-revision lift (`ProjectOnboard.revise_card` — scoped lift-push-restore);
  # the canonical `protect_main` rule does not name them, so an operator whitelist stays
  # untouched outside that one deliberate gesture.
  # `enable_status_check`/`status_check_contexts` ARE projected, and are NOT an "operator
  # enrichment" to leave alone: measured on a live bench (2026-08-03), every repo had
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
