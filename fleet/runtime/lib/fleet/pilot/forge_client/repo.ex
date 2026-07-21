defmodule Fleet.Pilot.ForgeClient.Repo do
  @moduledoc """
  **Repo provisioning** in the agent machine — sub-domain of `Fleet.Pilot.ForgeClient`:
  repo creation, discovery by org-membership (WS3), branch-protection, the repo's forge
  identity. (Admission is org membership, managed UPSTREAM by the human admin — no
  server-side admission marker, no mutable topic, no collaborator management here.)

  The *seam-faced* ops (`repo_id`, `list_org_repos`) are forwarded by `ForgeClient` (the module injected
  by the `:forge_client` seam stays it); the provisioning ops (`create_repo`, `protect_branch`)
  are called directly by `Fleet.Pilot.ProjectOnboard`.

  **Last revised**: 2026-07-21
  """

  import Fleet.Pilot.ForgeClient.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_patch: 3,
      http_delete: 2,
      paginate: 3
    ]

  # Safe encoding of URL segments (path-traversal lock) — single authority UrlSafe.
  import Fleet.Pilot.ForgeClient.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  @doc """
  Creates a repo on the forge. `opts[:org]` → `POST /orgs/<org>/repos` (org repo); otherwise
  `POST /user/repos` (the token's account). `auto_init: true` by default (initial commit + README
  → clonable right away). Idempotent: repo already present (HTTP 409) → `{:ok, :already_exists}` —
  provisioning converges on a re-run instead of erroring; any other failure IS returned as an error.

  ## Returns
    * `{:ok, full_name}` — repo created (e.g. `"fleet/poc-helloworld"`)
    * `{:ok, :already_exists}` — already present (409)
    * `{:error, term()}` — HTTP/transport/config
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
  Generates a NEW repo from a forge TEMPLATE repo — Gitea `POST /repos/{template}/generate`
  (native scaffolding, VERIFIED live on this forge 2026-07-18): git content copied with
  `${VAR}` expansion (files listed in the template's `.gitea/template`; REPO_NAME,
  REPO_DESCRIPTION, dates…), labels copied WITH their descriptions, own FRESH history
  (not a fork — no link back). `webhooks`/`protected_branch` deliberately NOT copied:
  `protect_branch` stays the single branch-protection writer (per-card sizing at onboard).

  `{:ok, full_name}` | `{:ok, :already_exists}` (409) | `{:error, :template_missing}`
  (404 — the template repo is not on the forge: run `mix lcars.project_template.sync`) |
  `{:error, term}`.
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
  Marks (or unmarks) a repo as a TEMPLATE — Gitea `PATCH /repos/{repo}` `{template: bool}`.
  Used by `mix lcars.project_template.sync` (the priv → forge projection); idempotent.
  """
  @spec set_template(String.t(), boolean(), keyword()) :: :ok | {:error, term()}
  def set_template(repo, template?, opts \\ []) when is_binary(repo) and is_boolean(template?) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <- http_patch(config, "/repos/#{encode_repo(repo)}", %{template: template?}) do
      :ok
    end
  end

  @doc """
  Repos of the org `org` — Gitea `GET /orgs/{org}/repos`, **PAGINATED**. **THE poller's
  discovery (WS3)**: org membership IS the admission (the org = the trust group, managed UPSTREAM by the
  human admin) — no mutable topic nor server-side seal. The per-human scoping stays `assigned_by`
  (issue-level, anti-theft guard: the fleet processes ONLY its issues, even if it sees the group's other
  repos). Returns the `full_name`s (`"owner/name"`).
  """
  @spec list_org_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_org_repos(org, opts \\ []) when is_binary(org) do
    # PAGINATED (DR-016/BND-057): THE poller's discovery is a source-of-truth collection consumed as "every
    # repo of the fleet org". A single `?limit=50` page silently HID repos 51+ (beyond 50 repos = invisible
    # projects: no dispatch, no reconciliation, no re-kick, no event nor error — the forge+poll backstop
    # broken in a zone the poll never re-reads). We loop like every other SSOT read (`paginate/3`: fail-loud
    # on an unexpected page shape via `:unexpected_page_shape`) — no "small-team org < 50" assumption.
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} <- paginate(config, "/orgs/#{encode_seg(org)}/repos", "") do
      {:ok, body |> Enum.map(&Map.get(&1, "full_name")) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  Default branch of `repo` — Gitea `GET /repos/{repo}` → `.default_branch`. Serves WS4 (import):
  the runtime's protection/clone assumes `main` EVERYWHERE (same convention as `create_repo`, `protect_main`);
  importing a repo whose default is NOT `main` is an explicit refusal (`Fleet.Pilot.ProjectOnboard.import/2`),
  not a generalization of the branch name — out-of-scope as long as no real repo needs it.
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
  Tip commit sha of `branch` on `repo` (Gitea `GET /repos/{repo}/branches/{branch}` →
  `commit.id`). Read by the seal's provenance wall (the deliverable head at merge time).
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
  Does the branch `branch` exist on `repo`? Gitea `GET /repos/{repo}/branches/{branch}` (200 = yes,
  404 = no). Serves WS4 (import): idempotence of `work/ops` — a re-imported (or already onboarded) repo
  must not have its orphan branch overwritten. `false` on any error (fail-safe: unconfirmed absence
  ⇒ we attempt creation, Gitea will refuse cleanly if it already exists).
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
  Does the forge account `username` exist? (`GET /users/<u>`). Distinguishes PROVEN absence
  (`{:ok, false}`, http 404) from a forge outage (`{:error, _}`) — F2:
  the onboarding preflight says "create the account" ONLY on proven absence, never
  on an outage (otherwise it would send the operator to create an account that exists).
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
  Is `username` a member of the org's `team`? (2 GETs: the org's team list
  → membership). Same tri-state contract as `user_exists?/2`: `{:ok, false}` = PROVEN
  absence (team found, member 404 — or nonexistent team: a human cannot be a
  member of an absent team, the SAME admin gesture creates both), `{:error, _}`
  = forge outage. F2 — the `humans` team is the admission gate of the
  humans (tofu-teams model, cf. ProjectOnboard).
  """
  @spec team_member?(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, boolean()} | {:error, term()}
  def team_member?(org, team, username, opts \\ [])
      when is_binary(org) and is_binary(team) and is_binary(username) do
    # PAGINATED: the org's teams — a single page HID team 51+, so the membership check for a team past
    # the first page (onboarding's "humans" gate, project_onboard) would falsely read "not a member".
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

  # `paginate` fail-louds a non-list page as `:unexpected_page_shape`; map it to the team-specific
  # `:unexpected_teams_shape` (never `{:ok, []}` — an empty team view here would wrongly deny membership).
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
  The repo's **numeric forge id** (`GET /repos/<repo>` → `.id`). It's the project's identity for the
  deterministic `session_id` (`Fleet.Spawner.SessionId`, `<REPO4>` segment): the FORGE is the
  source of truth, we do NOT derive an id from nothing. Gitea id = stable sequential integer (e.g.
  `fleet/lcars` = 145). `{:error, _}` if the repo doesn't exist / forge down → propagated to spawn identity:
  the caller puts NO `:repo_id` (nil), and a project-bound role spawned without a repo is an ANOMALY that
  fails loud in the mint (`Fleet.Spawner.Pod.SessionMint`) — never a random-UUID fallback.
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
  Places a **branch-protection** rule on `repo` — Gitea `POST /repos/{repo}/branch_protections`.
  `rule` = map of Gitea options (`rule_name`, `required_approvals`, `dismiss_stale_approvals`,
  `block_on_rejected_reviews`, `enable_push`, …). It's the **forge-enforced gate**: on the sandbox
  repo, the forge refuses the merge as long as the guards (N approvals, no REQUEST_CHANGES) are
  not green → the arbiter is the forge, not the runtime. Requires repo-admin.
  Idempotent: an already-placed rule → `:ok`. Gitea signals it with the precise message
  `"Branch protection already exist"` — carried across **403 / 409 / 422** depending on the version.
  We match on that MESSAGE, NEVER on the code alone: a 422 for an INVALID rule (bad payload) or a 403
  for a real permission refusal must NOT be announced as a protection that never took — those return a
  precise error and `lock_main` fails loud.
  """
  @spec protect_branch(String.t(), map(), Keyword.t()) :: :ok | {:error, term()}
  def protect_branch(repo, rule, opts \\ []) when is_binary(repo) and is_map(rule) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/branch_protections", rule) do
        {:ok, _} ->
          :ok

        # "already exist" (403/409/422 across versions, matched on the MESSAGE never the code
        # alone) used to read as a bare :ok with NO readback: an imported repo's stale rule —
        # or a card whose jury changed since onboarding — silently kept a main protection
        # weaker or stronger than the CURRENT projection. Desired-state instead: read the
        # existing rule back, compare ONLY the fields we project (a hand-enriched rule keeps
        # its extra fields), PATCH on divergence, fail loud when the readback/patch fails —
        # never claim a protection whose actual shape was not seen.
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
      # Nothing projected beyond the rule's existence — nothing to reconcile.
      :ok
    else
      case http_get(config, path) do
        {:ok, existing} when is_map(existing) ->
          if Map.take(existing, Map.keys(projected)) == projected do
            :ok
          else
            case http_patch(config, path, projected) do
              {:ok, _} -> :ok
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

  # The reconcilable surface = the protection fields `lock_main` sizes, restricted to those
  # the CALLER actually projected (string keys, the wire's shape on readback). Comparing or
  # patching MORE would clobber operator enrichments (status checks, push whitelists) the
  # runtime never projected.
  @protectable_fields ~w(required_approvals dismiss_stale_approvals block_on_rejected_reviews enable_push)

  defp projected_protection_fields(rule) do
    for {k, v} <- rule, sk = to_string(k), sk in @protectable_fields, into: %{}, do: {sk, v}
  end

  @doc """
  Deletes the repo `repo` (`"owner/name"`) on the forge — `DELETE /repos/{owner}/{repo}` (the
  branch-protection falls with it). Idempotent: a 404 (already gone) → `:ok`. Used by
  `Fleet.Pilot.ProjectOnboard.delete_project/2` (the general project teardown) — this is the raw
  primitive; the caller owns the `force`/confirmation gate.
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
