defmodule Fleet.Pilot.ForgeClient.Repo do
  @moduledoc """
  **Provisioning de repo** dans la machine à agents — sous-domaine de `Fleet.Pilot.ForgeClient` :
  création de repo, collaborateurs, découverte par appartenance-org (WS3), branch-protection, identité
  forge du repo. (Le sceau d'admission `post_onboard_marker`/`admitted?` + la découverte par topic
  `search_repos_by_topic`/`add_topic` sont RETIRÉS — l'admission est l'appartenance à l'org, gérée EN
  AMONT par l'admin humain ; plus de marqueur server-side à poser/lire.)

  Les ops *seam-faced* (`repo_id`, `list_org_repos`) sont forwardées par `ForgeClient` (le module injecté
  par le seam `:forge_client` reste lui) ; les ops de provisioning (`create_repo`, `add_collaborator`,
  `protect_branch`) sont appelées en direct par `Fleet.Pilot.ProjectOnboard`.
  """

  import Fleet.Pilot.ForgeClient.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_put: 3
    ]

  # Encodage sûr des segments d'URL (verrou path-traversal) — autorité unique UrlSafe.
  import Fleet.Pilot.ForgeClient.UrlSafe, only: [encode_repo: 1, encode_seg: 1]

  @doc """
  Crée un repo sur la forge. `opts[:org]` → `POST /orgs/<org>/repos` (repo d'org) ; sinon
  `POST /user/repos` (compte du token). `auto_init: true` par défaut (commit initial + README
  → clonable tout de suite). Idempotent best-effort : repo déjà présent (HTTP 409) → `{:ok, :already_exists}`.

  ## Returns
    * `{:ok, full_name}` — repo créé (ex `"fleet/poc-helloworld"`)
    * `{:ok, :already_exists}` — déjà présent (409)
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
  Ajoute/met à jour un **collaborateur** sur `repo` avec `permission` (`"read"|"write"|"admin"`) —
  Gitea `PUT /repos/{repo}/collaborators/{username}`. Idempotent (re-PUT = même perm). Requiert
  repo-admin (token système). L'onboarding donne le **write** aux comptes de rôle (engineer/
  qualifier/reviewer/gatekeeper) pour que leurs reviews comptent au gate de branch-protection et que
  le gatekeeper puisse merger.
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
  Repos de l'org `org` — Gitea `GET /orgs/{org}/repos`. **LA découverte du poller (WS3)** : l'appartenance
  à l'org EST l'admission (l'org = le groupe de confiance, gérée EN AMONT par l'admin humain) — plus de topic
  mutable ni de sceau server-side. Le scoping per-humain reste `assigned_by` (issue-level, garde anti-vol :
  la fleet ne traite QUE ses issues, même si elle voit les repos des autres du groupe). Retourne les
  `full_name` (`"owner/name"`). (limit=50 : une org small-team a < 50 repos actifs ; pagination = backlog.)
  """
  @spec list_org_repos(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_org_repos(org, opts \\ []) when is_binary(org) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} <- http_get(config, "/orgs/#{encode_seg(org)}/repos?limit=50") do
      {:ok, body |> List.wrap() |> Enum.map(&Map.get(&1, "full_name")) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  Branche par défaut de `repo` — Gitea `GET /repos/{repo}` → `.default_branch`. Sert à WS4 (import) :
  la protection/clone du runtime suppose `main` PARTOUT (même convention que `create_repo`, `protect_main`) ;
  importer un repo dont le défaut n'est PAS `main` est un refus explicite (`Fleet.Pilot.ProjectOnboard.import/2`),
  pas une généralisation du nom de branche — hors-scope tant qu'aucun repo réel n'en a besoin.
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
  La branche `branch` existe-t-elle sur `repo` ? Gitea `GET /repos/{repo}/branches/{branch}` (200 = oui,
  404 = non). Sert à WS4 (import) : idempotence de `work/ops` — un repo réimporté (ou déjà onboardé)
  ne doit pas se faire écraser son orphan branch. `false` sur toute erreur (fail-safe : absence non
  confirmée ⇒ on tente la création, Gitea refusera proprement si elle existe déjà).
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
  `username` est-il collaborateur de `repo` ? Gitea `GET /repos/{repo}/collaborators/{username}` (204 = oui,
  404 = non). `false` sur toute erreur (config/transport/404) — fail-safe (on ne défaut PAS sur un repo
  inaccessible). Sert au scoping « projet par défaut = repos où l'humain est collaborateur » (create_issue).
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
  Repo du **dernier issue travaillé** par `human`, SCOPÉ aux repos où il est **collaborateur**. Sert de
  projet par défaut quand l'arch appelle `create_issue` sans `project` explicite (≠ « dernier créé », jugé
  mauvais). Mécanique : issue-search global `assigned_by=<human>` → tri
  CLIENT-SIDE par `updated_at` desc (le `sort=` Gitea s'est révélé peu fiable) → 1ʳᵉ issue dont le repo passe
  `collaborator?/3` (l'`assigned_by` seul inclut des repos non-collaborateur, ex. vieux issues de test). `:none`
  si rien (fleet neuve / forge down). Il n'y a plus de repli config global : le repo cible d'une délégation
  est désormais passé explicitement par l'arch (`project`), jamais lu d'une mémoire de « projet courant ».
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
  L'**id forge numérique** du repo (`GET /repos/<repo>` → `.id`). C'est l'identité du projet pour le
  `session_id` déterministe (`Fleet.Spawner.SessionId`, segment `<REPO4>`) : la FORGE est la
  source de vérité, on ne dérive PAS un id du néant. Id Gitea = entier séquentiel stable (ex.
  `fleet/lcars` = 145). `{:error, _}` si le repo n'existe pas / forge down → l'appelant retombe sur un
  UUID random (best-effort, zéro collision).
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
  Pose une règle de **branch-protection** sur `repo` — Gitea `POST /repos/{repo}/branch_protections`.
  `rule` = map d'options Gitea (`rule_name`, `required_approvals`, `dismiss_stale_approvals`,
  `block_on_rejected_reviews`, `enable_push`, …). C'est le **gate forge-enforcé** : sur le repo
  sandbox, la forge refuse le merge tant que les gardes (N approvals, pas de REQUEST_CHANGES) ne sont
  pas vertes → l'arbitre est la forge, pas le runtime. Requiert repo-admin.
  Idempotent : une règle déjà posée → `:ok`. Vérifié empiriquement (WS4 e2e, 2026-07-07) : Gitea rend
  **403** `"Branch protection already exist"` pour ce cas précis — PAS 409/422 comme documenté avant
  (bug latent, présent aussi côté `onboard/2` sur tout re-run post-protect ; débusqué par l'idempotence
  testée d'`import/2`). On ne peut PAS avaler tout 403 (un vrai refus de permission serait masqué) →
  on matche le MESSAGE précis, pas juste le code.
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
