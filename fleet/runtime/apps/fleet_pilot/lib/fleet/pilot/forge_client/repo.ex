defmodule Fleet.Pilot.ForgeClient.Repo do
  @moduledoc """
  **Provisioning de repo + admission** dans la machine à agents — sous-domaine de `Fleet.Pilot.ForgeClient` :
  création de repo, collaborateurs, topics, branch-protection, découverte par topic, identité forge du repo,
  et le **sceau d'admission** non forgeable (`post_onboard_marker`/`admitted?`).

  Frontière : ce concern ne dépend du cœur issues/PR que par UNE arête descendante — `post_onboard_marker`
  matérialise le sceau comme une issue système (il appelle `Fleet.Pilot.ForgeClient.create_issue`/`close_issue`).
  C'est un LAYERING (l'onboarding orchestre des primitives d'issue), pas un couplage croisé.

  Les ops *seam-faced* (`repo_id`, `search_repos_by_topic`, `admitted?`) sont forwardées par `ForgeClient`
  (le module injecté par le seam `:forge_client` reste lui) ; les ops de provisioning (`create_repo`,
  `add_collaborator`, `add_topic`, `protect_branch`, `post_onboard_marker`) sont appelées en direct par
  `Fleet.Pilot.ProjectOnboard`.
  """

  import Fleet.Pilot.ForgeClient.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_put: 3,
      paginate: 3,
      forge_bot_login: 2,
      encode_repo: 1,
      encode_seg: 1
    ]

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.ForgeProtocol

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
  Recherche les repos dont un TOPIC matche `topic` — Gitea `GET /repos/search?q=&topic=true`.
  Multi-projet : le poller découvre SES projets via le topic per-humain `lcars-fleet-<human>` (posé par
  l'onboarding). Retourne les `full_name` (`"owner/name"`). Forme inattendue / aucun résultat → `{:ok, []}`.
  (limit=50 : un humain a < 50 projets actifs ; pagination = backlog si besoin.)
  """
  @spec search_repos_by_topic(String.t(), Keyword.t()) :: {:ok, [String.t()]} | {:error, term()}
  def search_repos_by_topic(topic, opts \\ []) when is_binary(topic) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, body} <-
           http_get(config, "/repos/search?topic=true&limit=50&q=" <> URI.encode_www_form(topic)) do
      repos = if is_map(body), do: Map.get(body, "data", []), else: []
      {:ok, repos |> List.wrap() |> Enum.map(&Map.get(&1, "full_name")) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  Ajoute le `topic` au `repo` — Gitea `PUT /repos/{repo}/topics/{topic}`. Idempotent (re-PUT = no-op).
  Multi-projet : l'onboarding tague le repo neuf `lcars-fleet-<human>` → découvrable par le poller.
  """
  @spec add_topic(String.t(), String.t(), Keyword.t()) :: :ok | {:error, term()}
  def add_topic(repo, topic, opts \\ []) when is_binary(repo) and is_binary(topic) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_put(config, "/repos/#{encode_repo(repo)}/topics/#{encode_seg(topic)}", nil) do
      :ok
    end
  end

  # ============================================================
  # Marqueur d'ADMISSION système — la frontière d'entrée dans la machine à agents.
  #
  # Le topic `lcars-fleet-<human>` rend un repo DÉCOUVRABLE, mais le topic est un champ Gitea
  # MUTABLE (`PUT /topics/{topic}`) que le propriétaire d'un repo peut poser lui-même. Le topic SEUL
  # admettrait donc n'importe quel repo qu'un user honnête a tagué + sur lequel il s'auto-assigne une
  # issue — un repo que le SYSTÈME n'a jamais onboardé entrerait comme projet légitime. L'admission
  # exige donc un sceau SERVEUR-SIDE NON FORGEABLE : un marqueur que SEUL le compte système peut poser.
  #
  # Le sceau = un marqueur d'onboarding écrit par le BOT système (le porteur de `FORGE_TOKEN`), vérifié
  # `system_authored?` à la lecture — exactement le mécanisme déjà éprouvé pour les marqueurs route/hop/
  # result (« un marqueur n'est cru que s'il est posté par le bot système »). Non forgeable parce qu'un
  # user ordinaire n'a pas le token système pour l'écrire SOUS l'identité du bot, PAS parce qu'il est
  # signé. Pas de crypto, pas de registre : le MÊME primitif de confiance, étendu à l'admission repo.
  # ============================================================

  @doc """
  Pose le marqueur d'admission `[lcars-onboarded:<human>]` sur `repo` — crée une issue SYSTÈME
  dédiée (`title` = le marqueur) sous le compte du token (= le bot système), PUIS la ferme aussitôt.
  L'issue, postée par le bot, EST le sceau : un user ordinaire ne peut pas la fabriquer SOUS l'identité
  du bot (il n'a pas le token système). La fermeture est cosmétique (tracker propre, pas d'issue ouverte
  parasite) et best-effort : l'admission tient sur titre+auteur, pas sur l'état (`admitted?` lit
  `state=all`), donc un sceau fermé — ou laissé ouvert sur échec de fermeture — reste valide. Idempotent
  best-effort : si une issue d'admission bot-authored existe déjà, `{:ok, :already}` (pas de doublon).
  Appelé par `ProjectOnboard.register_for_fleet` (token système).

  ## Returns
    * `{:ok, issue_number}` — marqueur posé (issue système créée puis fermée)
    * `{:ok, :already}` — déjà présent (issue d'admission bot-authored existante)
    * `{:error, term()}` — HTTP/transport/config / bot irrésoluble (création du sceau échouée)
  """
  @spec post_onboard_marker(String.t(), String.t(), Keyword.t()) ::
          {:ok, integer() | :already} | {:error, term()}
  def post_onboard_marker(repo, human, opts \\ []) when is_binary(repo) and is_binary(human) do
    marker = ForgeProtocol.onboard_marker(human)

    case admitted?(repo, human, opts) do
      true ->
        {:ok, :already}

      false ->
        # Le marqueur vit dans le TITRE de l'issue système (lu sans pagination de comments, stable). Le
        # corps explicite le rôle pour un humain qui tomberait dessus dans l'UI forge. L'arête descendante
        # vers le cœur : on matérialise le sceau via les primitives d'issue de `ForgeClient` (create/close).
        with {:ok, issue_number} <-
               ForgeClient.create_issue(
                 repo,
                 marker,
                 "Marqueur d'admission LCARS — ce repo est onboardé dans la machine à agents de `#{human}`.\n" <>
                   "Sceau serveur-side posé par le compte système, puis fermé aussitôt : l'admission ne " <>
                   "dépend QUE du titre + de l'auteur (le bot), jamais de l'état de l'issue. Ne pas renommer.",
                 opts
               ) do
          # Fermé immédiatement pour ne pas laisser d'issue ouverte parasite dans le tracker du repo.
          # Best-effort : l'admission tient sur titre+auteur, pas sur l'état (le lecteur `admitted?` lit
          # `state=all`) → un échec de fermeture laisse un sceau OUVERT tout aussi valide, l'onboarding ne
          # doit pas échouer pour ça. On garde donc le numéro et on ignore le retour de la fermeture.
          _ = ForgeClient.close_issue(repo, issue_number, opts)
          {:ok, issue_number}
        end
    end
  end

  @doc """
  `repo` est-il ADMIS dans la machine à agents de `human` = porte-t-il le marqueur d'admission
  `[lcars-onboarded:<human>]` posté PAR LE BOT SYSTÈME ? La frontière d'entrée du poller : le topic
  seul (mutable) ne suffit PLUS, il faut ce sceau bot-authored. Lit les issues du repo et cherche
  CELLE dont le titre = le marqueur ET l'auteur = le bot (`system_authored?`). Un user qui ouvre une
  issue homonyme NE passe PAS (son login ≠ bot). `false` sur toute erreur / bot irrésoluble — FAIL-
  CLOSED : un repo dont l'admission n'est pas VÉRIFIABLE n'est pas admis (jamais sur un doute).
  """
  @spec admitted?(String.t(), String.t(), Keyword.t()) :: boolean()
  def admitted?(repo, human, opts \\ []) when is_binary(repo) and is_binary(human) do
    marker = ForgeProtocol.onboard_marker(human)

    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, issues} when is_list(issues) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues", "state=all&type=issues") do
      Enum.any?(issues, fn issue ->
        Map.get(issue, "title") == marker and system_authored_issue?(issue, bot)
      end)
    else
      _ -> false
    end
  end

  # Une ISSUE est de confiance ssi son AUTEUR (`user.login`) = le bot système. Pendant de
  # `ForgeProtocol.system_authored?/2` (qui vise les COMMENTS) côté issue — même invariant : un marqueur
  # n'est cru que s'il vient du compte système (le porteur du token). Couvert par `admitted?`.
  defp system_authored_issue?(issue, bot_login)
       when is_map(issue) and is_binary(bot_login) and bot_login != "" do
    get_in(issue, ["user", "login"]) == bot_login
  end

  defp system_authored_issue?(_issue, _bot), do: false

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
  Idempotent : une règle déjà posée (409/422) → `:ok`.
  """
  @spec protect_branch(String.t(), map(), Keyword.t()) :: :ok | {:error, term()}
  def protect_branch(repo, rule, opts \\ []) when is_binary(repo) and is_map(rule) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{encode_repo(repo)}/branch_protections", rule) do
        {:ok, _} -> :ok
        {:error, {:http, code, _}} when code in [409, 422] -> :ok
        {:error, _} = err -> err
      end
    end
  end
end
