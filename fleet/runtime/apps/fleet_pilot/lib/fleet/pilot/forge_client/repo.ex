defmodule Fleet.Pilot.ForgeClient.Repo do
  @moduledoc """
  **Repo provisioning** in the agent machine — sub-domain of `Fleet.Pilot.ForgeClient`:
  repo creation, collaborators, discovery by org-membership (WS3), branch-protection, the repo's forge
  identity. (The `post_onboard_marker`/`admitted?` admission seal + the topic discovery
  `search_repos_by_topic`/`add_topic` are REMOVED — admission is org membership, managed
  UPSTREAM by the human admin; no more server-side marker to set/read.)

  The *seam-faced* ops (`repo_id`, `list_org_repos`) are forwarded by `ForgeClient` (the module injected
  by the `:forge_client` seam stays it); the provisioning ops (`create_repo`, `add_collaborator`,
  `protect_branch`) are called directly by `Fleet.Pilot.ProjectOnboard`.
  """

  import Fleet.Pilot.ForgeClient.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_put: 3
    ]

  # Safe encoding of URL segments (path-traversal lock) — single authority UrlSafe.
  import Fleet.Pilot.ForgeClient.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  @doc """
  Creates a repo on the forge. `opts[:org]` → `POST /orgs/<org>/repos` (org repo); otherwise
  `POST /user/repos` (the token's account). `auto_init: true` by default (initial commit + README
  → clonable right away). Best-effort idempotent: repo already present (HTTP 409) → `{:ok, :already_exists}`.

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
  Adds/updates a **collaborator** on `repo` with `permission` (`"read"|"write"|"admin"`) —
  Gitea `PUT /repos/{repo}/collaborators/{username}`. Idempotent (re-PUT = same perm). Requires
  repo-admin (system token). Onboarding grants **write** to the role accounts (engineer/
  qualifier/reviewer/gatekeeper) so that their reviews count at the branch-protection gate and so that
  the gatekeeper can merge.
  """
  @spec add_collaborator(String.t(), String.t(), String.t(), Keyword.t()) ::
          :ok | {:error, term()}
  def add_collaborator(repo, username, permission, opts \\ [])
      when is_binary(repo) and is_binary(username) and is_binary(permission) do
    with {:ok, config} <- resolve_config(opts) do
      case http_put(
             config,
             "/repos/#{encode_repo(repo)}/collaborators/#{encode_seg(username)}",
             %{permission: permission}
           ) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Repos of the org `org` — Gitea `GET /orgs/{org}/repos`. **THE poller's discovery (WS3)**: org
  membership IS the admission (the org = the trust group, managed UPSTREAM by the human admin) — no more mutable
  topic nor server-side seal. The per-human scoping stays `assigned_by` (issue-level, anti-theft guard:
  the fleet processes ONLY its issues, even if it sees the group's other repos). Returns the
  `full_name`s (`"owner/name"`). (limit=50: a small-team org has < 50 active repos; pagination = backlog.)
  """
  @spec list_org_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_org_repos(org, opts \\ []) when is_binary(org) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} <- http_get(config, "/orgs/#{encode_seg(org)}/repos?limit=50") do
      {:ok, body |> List.wrap() |> Enum.map(&Map.get(&1, "full_name")) |> Enum.reject(&is_nil/1)}
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
  Is `username` a collaborator of `repo`? Gitea `GET /repos/{repo}/collaborators/{username}` (204 = yes,
  404 = no). `false` on any error (config/transport/404) — fail-safe (we do NOT default on an
  inaccessible repo). Serves the "default project = repos where the human is a collaborator" scoping (create_issue).
  """
  @spec collaborator?(String.t(), String.t(), Keyword.t()) :: boolean()
  def collaborator?(repo, username, opts \\ []) when is_binary(repo) and is_binary(username) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_get(config, "/repos/#{encode_repo(repo)}/collaborators/#{encode_seg(username)}") do
      true
    else
      _ -> false
    end
  end

  @doc """
  Repo of the **last issue worked** by `human`, SCOPED to repos where they are a **collaborator**. Serves as
  the default project when the arch calls `create_issue` without an explicit `project` (≠ "last created", judged
  wrong). Mechanics: global issue-search `assigned_by=<human>` → CLIENT-SIDE sort
  by `updated_at` desc (Gitea's `sort=` proved unreliable) → 1st issue whose repo passes
  `collaborator?/3` (`assigned_by` alone includes non-collaborator repos, e.g. old test issues). `:none`
  if nothing (fresh fleet / forge down). There is no more global config fallback: a delegation's target repo
  is now passed explicitly by the arch (`project`), never read from a "current project" memory.
  """
  @spec last_worked_repo(String.t(), Keyword.t()) :: {:ok, String.t()} | :none
  def last_worked_repo(human, opts \\ []) when is_binary(human) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, issues} <-
           http_get(
             config,
             "/repos/issues/search?type=issues&state=all&limit=30&assigned_by=" <>
               URI.encode_www_form(human)
           ) do
      issues
      |> List.wrap()
      |> Enum.sort_by(&(&1["updated_at"] || ""), :desc)
      |> Enum.map(&get_in(&1, ["repository", "full_name"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.find(&collaborator?(&1, human, opts))
      |> case do
        repo when is_binary(repo) -> {:ok, repo}
        nil -> :none
      end
    else
      _ -> :none
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
  Idempotent: an already-placed rule → `:ok`. Empirically verified (WS4 e2e, 2026-07-07): Gitea returns
  **403** `"Branch protection already exist"` for this precise case — NOT 409/422 as documented before
  (latent bug, also present on the `onboard/2` side on any post-protect re-run; flushed out by the tested
  idempotence of `import/2`). We CANNOT swallow every 403 (a real permission refusal would be masked) →
  we match the precise MESSAGE, not just the code.
  """
  @spec protect_branch(String.t(), map(), Keyword.t()) :: :ok | {:error, term()}
  def protect_branch(repo, rule, opts \\ []) when is_binary(repo) and is_map(rule) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/branch_protections", rule) do
        {:ok, _} ->
          :ok

        {:error, {:http, code, _}} when code in [409, 422] ->
          :ok

        {:error, {:http, 403, %{"message" => msg}}} when is_binary(msg) ->
          if String.contains?(msg, "already exist"),
            do: :ok,
            else: {:error, {:http, 403, %{"message" => msg}}}

        {:error, _} = err ->
          err
      end
    end
  end
end
