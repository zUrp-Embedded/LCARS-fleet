defmodule Fleet.Pilot.ForgeClient do
  @moduledoc """
  Client minimal Gitea REST API pour `fleet_pilot`. Une seule
  opération : `add_label/4` (PUT label set idempotent) — utilisée par
  `Fleet.Pilot.AutoDispatcher` pour poser le lock `lcars-dispatched`
  avant invoke pipeline.

  ## Configuration

  Résolue à l'appel via `opts` (Keyword) ou fallback
  `Application.get_env(:fleet_pilot, :forge)` :

    * `:base_url` — ex `"http://localhost:3000"` (laptop mirror) ou
      `"http://10.42.0.118"` (forge NAS).
    * `:token` — token Gitea. Lu depuis `:token_file` si absent.
    * `:token_file` — path fichier (défaut `~/.gitea_token`, convention
      v1.5).
    * `:req_options` — options passées tel quel à `Req.new/1` (pour
      tests : `[plug: ...]` pour intercepter HTTP).

  ## Idempotence

  Pattern `GET issue labels + PUT label set` (cf. v1.5
  `gitea/gitea-client.py:135-138` : ticket 153-D — POST append cause
  doublons). Re-call sur label déjà présent = `{:ok, :already_present}`,
  zéro round-trip d'écriture.

  ## Pas de cache

  Chaque `add_label/4` re-fetche `/labels?limit=100` (mapping name→id).
  ~2KB, LAN-rapide. Optimisation cache (`:persistent_term`) à voir si
  contention mesurée.
  """

  require Logger

  @type config :: %{
          base_url: String.t(),
          token: String.t(),
          req_options: Keyword.t()
        }

  @doc """
  Ajoute le label `label_name` à l'issue `repo`/`issue_number` côté
  forge. Idempotent : si le label est déjà présent, aucune écriture.

  ## Returns

    * `{:ok, :added}` — label fraîchement ajouté
    * `{:ok, :already_present}` — label déjà sur l'issue (no-op)
    * `{:error, {:label_unknown, label_name}}` — label n'existe pas
      dans le repo (à pre-provisioner côté forge)
    * `{:error, {:http, status, body}}` — réponse HTTP non-2xx
    * `{:error, {:transport, reason}}` — échec réseau / DNS / ...
    * `{:error, {:config, reason}}` — config manquante / token illisible
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
  Liste les issues ouvertes du `repo` qui n'ont PAS le label `exclude_label`
  (filtrage client-side : Gitea n'expose pas la négation côté query).
  Utilisé par `Fleet.Pilot.Poller` (catch-up tickets sans
  `lcars-dispatched`).

  ## Returns

    * `{:ok, [issue]}` — issues filtrées, payloads bruts Gitea
    * `{:error, term()}` — propagation des erreurs HTTP/transport/config

  ## Pagination

  Limite hard-coded à 50 issues/page, 1 seule page. Pour les opérations
  catch-up, ça couvre largement la fenêtre de catch-up post-crash. Si
  le poller doit traiter +50 issues entre 2 ticks, c'est un signe que
  l'interval est trop long ou la forge en burst — sujet de tuning, pas
  de PR (cf. v1.5 `LcarsFleetPoller` même limite).
  """
  @spec list_open_issues_without_label(String.t(), String.t(), Keyword.t()) ::
          {:ok, [map()]} | {:error, term()}
  def list_open_issues_without_label(repo, exclude_label, opts \\ [])
      when is_binary(repo) and is_binary(exclude_label) do
    with {:ok, issues} <- list_open_issues(repo, opts) do
      filtered =
        Enum.reject(issues, fn issue ->
          labels = Map.get(issue, "labels", [])
          Enum.any?(labels, fn l -> Map.get(l, "name") == exclude_label end)
        end)

      {:ok, filtered}
    end
  end

  @doc """
  Liste TOUTES les issues ouvertes du `repo` (Gitea `GET /repos/{repo}/issues?state=open`), sans
  filtre. Brique du bail dispatch repo-serialise : le Poller compte les pipelines actifs = tickets
  deja assignes a un role (in-flight INCLUS, contrairement a `list_open_issues_without_label/3`) ->
  un seul pipeline a la fois par repo (merge FF garanti). Limite 50/page, 1 page (cf. catch-up).
  """
  @spec list_open_issues(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_issues(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts) do
      http_get(config, "/repos/#{repo}/issues?state=open&type=issues&limit=50")
    end
  end

  # ============================================================
  # Write-ops — primitives mécaniques de fin-de-hop (DN forge-state-machine §5)
  # Toutes idempotentes (skip si l'état cible est déjà atteint).
  # ============================================================

  @doc """
  Réassigne l'issue à `login` (1-assignee strict, DN §10). PATCH `assignees: [login]`
  remplace la liste. Idempotent : `{:ok, :already}` si `login` est déjà le seul assignee.
  """
  @spec set_assignee(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :set | :already} | {:error, term()}
  def set_assignee(repo, issue_number, login, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) and is_binary(login) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, issue} <- http_get(config, "/repos/#{repo}/issues/#{issue_number}") do
      current = Enum.map(Map.get(issue, "assignees") || [], & &1["login"])

      if current == [login] do
        {:ok, :already}
      else
        case http_patch(config, "/repos/#{repo}/issues/#{issue_number}", %{assignees: [login]}) do
          {:ok, _} -> {:ok, :set}
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc """
  Transition de `state:*` (DN §5 étape 3) : retire tout label `state:*` existant et pose
  `new_state`. Les labels non-`state:*` (dont `lcars-in-flight`) sont conservés. Idempotent.
  """
  @spec set_state_label(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :set} | {:error, term()}
  def set_state_label(repo, issue_number, new_state, opts \\ [])
      when is_binary(new_state) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, current} <- get_issue_labels(config, repo, issue_number) do
      # Par NOM (Gitea résout repo+ORG côté serveur) : on garde les labels non-`state:*` et on pose
      # `new_state`. PUT remplace l'ensemble — on lui passe les NOMS (verrous + état), pas des repo-ids.
      kept_names =
        current
        |> Enum.reject(fn l ->
          String.starts_with?(l["name"] || "", Fleet.Pilot.Labels.state_prefix())
        end)
        |> Enum.map(& &1["name"])

      case put_issue_labels(config, repo, issue_number, Enum.uniq([new_state | kept_names])) do
        :ok -> {:ok, :set}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Poste un comment (DN §5 étape 2). Si `:dedup_signature` est fourni et qu'un comment **système**
  existant la contient déjà, no-op (`{:ok, :already}`) — la signature `[hop:<role>:<sha>]` rend le
  replay idempotent. Le dédup ne fait foi QUE des comments du bot (F058 suivi-review) : sinon un
  user forge postant la signature en avance supprimerait le comment système (→ `count_signed_hops`
  sous-compterait). Bot irrésoluble → dédup non filtré (fail-open vers la sûreté du replay).
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
        case http_post(config, "/repos/#{repo}/issues/#{issue_number}/comments", %{body: body}) do
          {:ok, _} -> {:ok, :posted}
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc """
  Retire le label `label_name` (DN §5 étape 5 : release du verrou `lcars-in-flight`).
  Idempotent : `{:ok, :already_absent}` si le label n'est pas présent.
  """
  @spec remove_label(String.t(), integer(), String.t(), Keyword.t()) ::
          {:ok, :removed | :already_absent} | {:error, term()}
  def remove_label(repo, issue_number, label_name, opts \\ [])
      when is_binary(label_name) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, current} <- get_issue_labels(config, repo, issue_number) do
      # L'`id` vient des labels ATTACHÉS à l'issue (`current`), pas d'un index repo (qui rate les
      # org-labels) : un org-label attaché y figure avec son id → DELETE marche pour repo ET org.
      case Enum.find(current, &(&1["name"] == label_name)) do
        nil ->
          {:ok, :already_absent}

        %{"id" => id} ->
          case request(config, :delete, "/repos/#{repo}/issues/#{issue_number}/labels/#{id}", nil) do
            {:ok, _} -> {:ok, :removed}
            {:error, _} = err -> err
          end
      end
    end
  end

  @doc """
  Ferme l'issue (DN §14 terminal de chaîne). PATCH `state: closed`. Idempotent côté Gitea.
  """
  @spec close_issue(String.t(), integer(), Keyword.t()) :: {:ok, :closed} | {:error, term()}
  def close_issue(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_patch(config, "/repos/#{repo}/issues/#{issue_number}", %{state: "closed"}) do
      {:ok, :closed}
    end
  end

  # ============================================================
  # Onboarding projet (Rail 1 e2e 2026-06-14) — création repo + issue.
  # Greffe sur le plumbing http_post existant ; le token système (lcars-system)
  # doit porter write:organization (repo) + write:issue.
  # ============================================================

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
          org when is_binary(org) and org != "" -> "/orgs/#{org}/repos"
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
  Crée une issue (ticket) sur `repo`. `opts[:assignees]` = logins, `opts[:labels]` = IDs entiers
  (le label `type:*` de routage se pose plutôt via `add_label/4` après, résolution name→id).
  Retourne le numéro d'issue.

  ## Returns
    * `{:ok, issue_number}` — issue créée
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

      case http_post(config, "/repos/#{repo}/issues", attrs) do
        {:ok, %{"number" => number}} -> {:ok, number}
        {:error, _} = err -> err
      end
    end
  end

  # ============================================================
  # Pull requests (BL-044 / Corr.3 git-native) — la PR est la surface de la phase
  # REVIEW+PROMOTE : domicile durable des verdicts de gate (review native Gitea) et
  # entonnoir unique vers `main`. Barrière §4 : le SYSTÈME ouvre/review/merge, le pod
  # n'a jamais le token. Primitives IDEMPOTENTES (rejouables sans casser).
  # ============================================================

  @doc """
  Ouvre une pull request `head` → `base` sur `repo` (Gitea `POST /repos/{repo}/pulls`).
  IDEMPOTENT : si une PR ouverte existe déjà pour cette `head`, retourne son numéro (le
  409 Gitea n'est pas une erreur). `opts[:body]` = corps — y mettre `Closes #N` pour
  l'auto-close de l'issue au merge (la forge maintient le lien ticket↔PR).

  ## Returns
    * `{:ok, number}` — PR ouverte (ou déjà existante)
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec open_pr(String.t(), String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def open_pr(repo, head, base, title, opts \\ [])
      when is_binary(repo) and is_binary(head) and is_binary(base) and is_binary(title) do
    with {:ok, config} <- resolve_config(opts) do
      attrs = %{head: head, base: base, title: title, body: Keyword.get(opts, :body, "")}

      case http_post(config, "/repos/#{repo}/pulls", attrs) do
        {:ok, %{"number" => number}} -> {:ok, number}
        # PR déjà ouverte pour cette head (Gitea 409) → idempotence : on la retrouve.
        {:error, {:http, 409, _}} -> get_pr_for_branch(repo, head, base, opts)
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Retrouve la PR OUVERTE `head` → `base` sur `repo` (Gitea `GET /repos/{repo}/pulls`, filtré
  côté client par `head.ref`/`base.ref`). Brique d'idempotence d'`open_pr/5`.

  ## Returns
    * `{:ok, number}` — PR trouvée
    * `{:error, :pr_not_found}` — aucune PR ouverte head→base
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec get_pr_for_branch(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, integer()} | {:error, term()}
  def get_pr_for_branch(repo, head, base, opts \\ [])
      when is_binary(repo) and is_binary(head) and is_binary(base) do
    with {:ok, config} <- resolve_config(opts) do
      case http_get(config, "/repos/#{repo}/pulls?state=open&limit=50") do
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
  Demande la review des `reviewers` (logins) sur la PR `index` (Gitea
  `POST /repos/{repo}/pulls/{index}/requested_reviewers`). C'est la mécanique de
  DÉCLENCHEMENT de la phase judge — remplace `set_assignee` côté PR (le poller spawn le
  juge sur la review-request).
  """
  @spec request_review(String.t(), integer(), [String.t()], Keyword.t()) ::
          :ok | {:error, term()}
  def request_review(repo, index, reviewers, opts \\ [])
      when is_binary(repo) and is_integer(index) and is_list(reviewers) do
    with {:ok, config} <- resolve_config(opts) do
      case http_post(config, "/repos/#{repo}/pulls/#{index}/requested_reviewers", %{
             reviewers: reviewers
           }) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Poste une review native sur la PR `index` (Gitea `POST /repos/{repo}/pulls/{index}/reviews`).
  `event` ∈ `:approve | :request_changes | :comment` → c'est le DOMICILE durable du verdict de
  gate (review native traçable, vs l'ancien comment-JSON maison). `body` = le verdict lisible.
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
      case http_post(config, "/repos/#{repo}/pulls/#{index}/reviews", %{
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
  Merge (PROMOTE) la PR `index` en FAST-FORWARD-ONLY (Gitea `POST /repos/{repo}/pulls/{index}/merge`,
  `Do: fast-forward-only` par défaut). Sous bail serial + funnel append-only, la feature est
  descendante linéaire de `main` → FF garanti, zéro merge commit. Un échec FF = invariant serial
  violé (deux branches sur le même code) → fail-loud, PAS un conflit à résoudre. `opts[:method]`
  override le style (`squash`/`merge`/`rebase`) si un jour nécessaire.
  """
  @spec merge_pr(String.t(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def merge_pr(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts) do
      body = %{"Do" => Keyword.get(opts, :method, "fast-forward-only")}

      case http_post(config, "/repos/#{repo}/pulls/#{index}/merge", body) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Liste les PR OUVERTES du `repo` (Gitea `GET /repos/{repo}/pulls?state=open`). Brique du dispatch
  juge PR-driven (Corr.3 4-C) : le Poller lit les `requested_reviewers` en attente d'une PR pour
  spawner le role juge (remplace l'assignee de l'issue). Chaque PR porte `number`, `head.ref` (la
  feature-branch `lcars/issue-N-role`), `requested_reviewers`, `labels`. Limite 50/page.
  """
  @spec list_open_pulls(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_pulls(repo, opts \\ []) when is_binary(repo) do
    with {:ok, config} <- resolve_config(opts) do
      http_get(config, "/repos/#{repo}/pulls?state=open&limit=50")
    end
  end

  @feature_branch_rx ~r{^lcars/issue-(\d+)-(.+)$}

  @doc """
  Extrait `{issue_number, role}` d'une feature-branch systeme `lcars/issue-<n>-<role>` (format pose
  par `HopConsumer.build_deliverable_opts` / `StageDispatcher`, convention F071). Sert au dispatch
  juge PR-driven a remonter de la PR (head.ref) au ticket. `:error` si le ref n'est pas une
  feature-branch fleet (PR externe / branche manuelle -> ignoree par le dispatch, jamais misroutee).
  """
  @spec parse_feature_branch(String.t()) :: {:ok, {integer(), String.t()}} | :error
  def parse_feature_branch(head) when is_binary(head) do
    case Regex.run(@feature_branch_rx, head) do
      [_, n, role] -> {:ok, {String.to_integer(n), role}}
      _ -> :error
    end
  end

  def parse_feature_branch(_), do: :error

  @doc """
  Etat de review COURANT d'une PR (Gitea `GET /repos/{repo}/pulls/{index}/reviews`) : la DERNIERE
  review decisive non-dismissed. Sert au dispatch du rework juge (Corr.3 4-C-iv) : une PR sans
  reviewer en attente mais avec un `REQUEST_CHANGES` courant -> le producteur doit reprendre.

  Les reviews `REQUEST_REVIEW`/`COMMENT`/`PENDING` ne sont pas decisives (ignorees). Gitea liste
  par ordre de creation -> la derniere decisive = le verdict en vigueur.

  ## Returns
    * `{:ok, :approved}` — derniere decisive = APPROVED
    * `{:ok, :changes_requested}` — derniere decisive = REQUEST_CHANGES
    * `{:ok, :none}` — aucune review decisive
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec pr_review_state(String.t(), integer(), Keyword.t()) ::
          {:ok, :approved | :changes_requested | :none} | {:error, term()}
  def pr_review_state(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, reviews} when is_list(reviews) <-
           http_get(config, "/repos/#{repo}/pulls/#{index}/reviews") do
      state =
        reviews
        |> Enum.reject(&Map.get(&1, "dismissed", false))
        |> Enum.filter(&(&1["state"] in ["APPROVED", "REQUEST_CHANGES"]))
        |> List.last()
        |> decisive_state()

      {:ok, state}
    else
      {:ok, _non_list} -> {:ok, :none}
      {:error, _} = err -> err
    end
  end

  defp decisive_state(%{"state" => "APPROVED"}), do: :approved
  defp decisive_state(%{"state" => "REQUEST_CHANGES"}), do: :changes_requested
  defp decisive_state(_), do: :none

  @doc """
  Écrit un fichier `path` (texte `content`) sur `repo`/`branch` — Gitea
  `PUT /repos/{repo}/contents/{path}`. **Le SYSTÈME publie** (forge-aveugle : le pod ne
  pousse jamais ; c'est ce chemin qui grave durablement le livrable d'un engineer). Création
  (pas d'update sha) : viser un `path` neuf (ticket-namespacé). Branche existante requise
  (défaut `main`) — `opts[:new_branch]` pour brancher depuis `branch`.

  ## Returns
    * `{:ok, commit_sha}` — fichier écrit
    * `{:error, term()}` — HTTP/transport/config (422 = path déjà présent sur la branche)
  """
  @spec put_file(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, String.t()} | {:error, term()}
  def put_file(repo, path, content, opts \\ [])
      when is_binary(repo) and is_binary(path) and is_binary(content) do
    with {:ok, config} <- resolve_config(opts) do
      body =
        %{
          content: Base.encode64(content),
          message: Keyword.get(opts, :message, "feat(fleet): #{path}"),
          branch: Keyword.get(opts, :branch, "main")
        }
        |> maybe_put_new_branch(Keyword.get(opts, :new_branch))
        # Traça à 2 niveaux (git-natif, 2026-06-14) : `author` = le WORKER (qui a écrit),
        # `committer` = l'HUMAIN commanditaire (qui a fait bosser la fleet ; le système fait l'I/O,
        # mais le commit attribue les deux niveaux). forge-aveugle préservé (le pod ne pousse jamais).
        |> maybe_put_identity(:author, Keyword.get(opts, :author))
        |> maybe_put_identity(:committer, Keyword.get(opts, :committer))

      case http_put(config, "/repos/#{repo}/contents/#{path}", body) do
        {:ok, %{"commit" => %{"sha" => sha}}} -> {:ok, sha}
        {:ok, _other} -> {:ok, :written}
        {:error, _} = err -> err
      end
    end
  end

  defp maybe_put_new_branch(body, nil), do: body
  defp maybe_put_new_branch(body, nb) when is_binary(nb), do: Map.put(body, :new_branch, nb)

  defp maybe_put_identity(body, key, %{name: name, email: email})
       when is_binary(name) and is_binary(email),
       do: Map.put(body, key, %{name: name, email: email})

  defp maybe_put_identity(body, _key, _), do: body

  defp comment_signed?(config, repo, issue_number, sig, opts) do
    case http_get(config, "/repos/#{repo}/issues/#{issue_number}/comments?limit=50") do
      {:ok, comments} when is_list(comments) ->
        # F058 (suivi review) : le dédup garde une ÉCRITURE système → ne fait foi que des comments
        # du bot. Sinon un user forge poste la signature en avance → le comment système est skipé →
        # `count_signed_hops` sous-compte (budget anti-runaway sur-permissif). Bot irrésoluble →
        # fail-OPEN (dédup non filtré) : au pire un comment dupliqué au replay, jamais une suppression
        # silencieuse d'un marqueur load-bearing.
        trusted =
          case forge_bot_login(config, opts) do
            {:ok, bot} -> Enum.filter(comments, &system_authored?(&1, bot))
            {:error, _} -> comments
          end

        Enum.any?(trusted, fn c -> String.contains?(c["body"] || "", sig) end)

      _ ->
        false
    end
  end

  # ============================================================
  # Marqueur ROUTE — position carte sur la forge (A2.1, DN forge-state-machine §8)
  # `[lcars-route:<pipeline>:<stage>]` : grave (pipeline, stage) sur l'issue, car l'assignee
  # (= rôle) seul n'identifie pas le stage (un rôle peut être sur N stages, cf. CarteNav).
  # Écrit à l'assignation (entrée + reassign), lu par StageDispatcher au spawn.
  # ============================================================

  @route_prefix "[lcars-route:"

  @doc """
  Grave le marqueur route `[lcars-route:<pipeline>:<stage>]`. Idempotent (dédup sur le marqueur
  exact → un replay ne duplique pas). Le dernier marqueur posé fait foi (cf. `get_route`).
  """
  @spec post_route(String.t(), integer(), String.t(), String.t(), Keyword.t()) ::
          {:ok, :posted | :already} | {:error, term()}
  def post_route(repo, issue_number, pipeline, stage, opts \\ [])
      when is_binary(pipeline) and is_binary(stage) do
    marker = "#{@route_prefix}#{pipeline}:#{stage}]"
    post_comment(repo, issue_number, marker, Keyword.put(opts, :dedup_signature, marker))
  end

  @doc """
  Lit la position carte courante = le **dernier** marqueur `[lcars-route:p:s]` de l'issue.
  `:none` si aucun (ticket hors-carte / 1-stage). `{:error, _}` sur échec HTTP/config.
  """
  @spec get_route(String.t(), integer(), Keyword.t()) ::
          {:ok, {String.t(), String.t()}} | :none | {:error, term()}
  def get_route(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           http_get(config, "/repos/#{repo}/issues/#{issue_number}/comments?limit=50") do
      # F058 : ne faire foi QUE des comments écrits par le compte SYSTÈME (bot). Un user forge
      # (humain/attaquant) qui poste `[lcars-route:evil:stage]` pilotait sinon la navigation.
      comments
      |> Enum.filter(&system_authored?(&1, bot))
      |> Enum.map(& &1["body"])
      |> Enum.reverse()
      |> Enum.find_value(:none, fn body -> parse_route_marker(body) end)
    end
  end

  @doc false
  # Pur : extrait `{pipeline, stage}` d'un body contenant `[lcars-route:p:s]`, sinon nil.
  def parse_route_marker(nil), do: nil

  def parse_route_marker(body) when is_binary(body) do
    case Regex.run(~r/\[lcars-route:([^:\]]+):([^:\]]+)\]/, body) do
      [_, pipeline, stage] -> {:ok, {pipeline, stage}}
      _ -> nil
    end
  end

  @hop_marker_rx ~r/\[hop:[^:\]]+:[^:\]]+\]/

  @doc """
  Format du marqueur de hop signé `[hop:<role>:<sha>]` (F064 : co-localisé avec son
  parseur `@hop_marker_rx` / `count_signed_hops` — un changement de format se fait ICI,
  le regex en face, jamais l'un sans l'autre). Posé par `HopCompleter` en fin-de-hop,
  sert aussi de `:dedup_signature` (replay idempotent).
  """
  @spec hop_marker(String.t(), String.t()) :: String.t()
  def hop_marker(role, sha) when is_binary(role) and is_binary(sha) do
    "[hop:#{role}:#{sha}]"
  end

  @doc """
  Compte les comments portant un marqueur de hop signé `[hop:<role>:<sha>]`
  (posés par `HopCompleter` à chaque fin-de-hop). Sert de compteur **forge-natif**
  au bound anti-runaway du rebond de gate (A2.3) : combien de hops ont déjà été
  joués sur l'issue. Monotone (les comments ne sont pas retirés), idempotent à lire.

  `{:error, _}` sur échec HTTP/config — le caller NE rebondit PAS à l'aveugle si le
  budget n'est pas vérifiable (un rebond non vérifiable pourrait boucler).

  NB : `?limit=50` — le budget de rework (`nb_stages * (max_rounds+1)`, ~quelques
  unités) est très en-dessous, donc pas de pagination ici. Si un jour le budget
  approche 50, paginer (même limite que `get_route`).
  """
  @spec count_signed_hops(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_signed_hops(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           http_get(config, "/repos/#{repo}/issues/#{issue_number}/comments?limit=50") do
      # F059 : compter SEULEMENT les hops signés par le SYSTÈME — sinon un user forge forge des
      # `[hop:role:sha]` pour gonfler le compteur et faire TRIPPER le budget anti-runaway (DoS rework).
      # Bot irrésoluble → {:error} (via le with) : le caller NE rebondit PAS sur un budget non vérifiable.
      count =
        comments
        |> Enum.filter(&system_authored?(&1, bot))
        |> Enum.map(& &1["body"])
        |> Enum.count(fn b -> is_binary(b) and Regex.match?(@hop_marker_rx, b) end)

      {:ok, count}
    end
  end

  @result_block_rx ~r/```result\n(.*?)\n```/s
  @result_fence_limit 8192

  @doc """
  Format du bloc ` ```result ` (sérialise les `outputs` d'un stage dans le comment de hop).
  F064 : co-localisé avec son parseur `parse_result_block/1` — round-trip garanti. `nil`/vide →
  `""` (pas de bruit). JSON fencé si ≤ 8 KB ; au-delà, une note pointant vers le livrable de la
  branche (jamais de JSON tronqué = invalide). Préfixe `\\n\\n` inclus (séparateur du corps).
  """
  @spec result_block(map() | nil) :: String.t()
  def result_block(outputs) when is_map(outputs) and map_size(outputs) > 0 do
    json = Jason.encode!(outputs)

    if byte_size(json) <= @result_fence_limit do
      "\n\n```result\n#{json}\n```"
    else
      "\n\n_(result #{byte_size(json)} o — trop volumineux pour le comment ; livrable complet sur la branche système)_"
    end
  end

  def result_block(_), do: ""

  @doc """
  Extrait le dernier bloc ` ```result ` posté dans un comment de hop — le `result_K`
  gravé par `HopCompleter` quand le stage avance vers un gatekeeper (A2.3b N-04). Sert
  à `StageDispatcher` pour donner au pod gatekeeper **quoi juger** dans son mandat
  (option B : pas de clone de branche). `:none` si aucun ; `{:error, _}` HTTP/config.
  """
  @spec get_predecessor_result(String.t(), integer(), Keyword.t()) ::
          {:ok, map()} | :none | {:error, term()}
  def get_predecessor_result(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           http_get(config, "/repos/#{repo}/issues/#{issue_number}/comments?limit=50") do
      # F060 (le plus grave) : le bloc ```result nourrit le MANDAT DE JUGEMENT du gatekeeper. Ne
      # l'extraire QUE de comments SYSTÈME — sinon un user forge injecte ce que le juge évalue.
      comments
      |> Enum.filter(&system_authored?(&1, bot))
      |> Enum.map(& &1["body"])
      |> Enum.reverse()
      |> Enum.find_value(:none, &parse_result_block/1)
    end
  end

  @doc false
  # Pur : extrait le map du dernier bloc ```result d'un body, sinon nil.
  def parse_result_block(body) when is_binary(body) do
    case Regex.run(@result_block_rx, body) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_result_block(_), do: nil

  @doc false
  # Pur (F058/F059/F060) : un comment est DE CONFIANCE ssi son auteur = le compte système (bot)
  # de la fleet. Un user forge (humain/attaquant) a un autre login → ses marqueurs sont ignorés.
  def system_authored?(comment, bot_login)
      when is_map(comment) and is_binary(bot_login) and bot_login != "" do
    get_in(comment, ["user", "login"]) == bot_login
  end

  def system_authored?(_comment, _bot), do: false

  # Login du compte système (le propriétaire de FORGE_TOKEN). Config `:forge_bot_login` (déploiement)
  # OU dérivé une fois via `GET /user` (l'authentifié du token), caché. Irrésoluble → `{:error}` :
  # les callers refusent alors de faire foi de marqueurs non vérifiables (fail-closed).
  defp forge_bot_login(config, opts) do
    # opts (seam test) > config (déploiement) > dérivé /user (caché).
    case Keyword.get(opts, :forge_bot_login) ||
           Application.get_env(:fleet_pilot, :forge_bot_login) do
      login when is_binary(login) and login != "" -> {:ok, login}
      _ -> derive_bot_login(config)
    end
  end

  defp derive_bot_login(config) do
    case :persistent_term.get({__MODULE__, :bot_login}, :unset) do
      login when is_binary(login) ->
        {:ok, login}

      :unset ->
        case http_get(config, "/user") do
          {:ok, %{"login" => login}} when is_binary(login) and login != "" ->
            :persistent_term.put({__MODULE__, :bot_login}, login)
            {:ok, login}

          {:ok, _} ->
            {:error, :bot_login_unresolved}

          {:error, _} = err ->
            err
        end
    end
  end

  # ============================================================
  # HTTP plumbing
  # ============================================================

  defp get_issue_labels(config, repo, issue_number) do
    case http_get(config, "/repos/#{repo}/issues/#{issue_number}/labels") do
      {:ok, labels} when is_list(labels) -> {:ok, labels}
      {:error, _} = err -> err
    end
  end

  # ADD un label par NOM (POST = ajoute sans remplacer l'existant). Gitea résout le nom contre les
  # labels REPO **et ORG** côté serveur (`IssueLabelsOption.labels` = « strings representing label
  # names », doc swagger) → plus de résolution repo-id côté client (qui ratait les org-labels). Les
  # labels-verrous du wire-protocol vivent au niveau ORG `fleet` (config fleet, une fois, pas par-repo).
  defp add_issue_label(config, repo, issue_number, label_name) do
    case http_post(config, "/repos/#{repo}/issues/#{issue_number}/labels", %{labels: [label_name]}) do
      {:ok, _body} -> :ok
      {:error, _} = err -> err
    end
  end

  # PUT (remplace l'ensemble) par NOMS — Gitea résout repo+ORG côté serveur (cf. `add_issue_label`).
  defp put_issue_labels(config, repo, issue_number, label_names) do
    case http_put(
           config,
           "/repos/#{repo}/issues/#{issue_number}/labels",
           %{labels: label_names}
         ) do
      {:ok, _body} -> :ok
      {:error, _} = err -> err
    end
  end

  defp http_get(config, path), do: request(config, :get, path, nil)
  defp http_put(config, path, body), do: request(config, :put, path, body)
  defp http_post(config, path, body), do: request(config, :post, path, body)
  defp http_patch(config, path, body), do: request(config, :patch, path, body)

  defp request(config, method, path, body) do
    url = config.base_url <> "/api/v1" <> path

    # `retry: false` — le retry HTTP est délégué au caller :
    # `Fleet.Pilot.Poller` a son propre backoff exponentiel + jitter
    # (5min cap, anti-thundering-herd), et `AutoDispatcher` traite un
    # event à la fois en serial. Le retry built-in Req (1s/2s/4s sur
    # 5xx) duplicaterait cette logique + ralentirait les tests d'erreur
    # de 7s par cas.
    req_opts =
      [
        method: method,
        url: url,
        headers: [
          {"authorization", "token " <> config.token},
          {"accept", "application/json"}
        ],
        receive_timeout: 10_000,
        retry: false
      ]
      |> maybe_put(:json, body)
      |> Keyword.merge(config.req_options)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ============================================================
  # Config resolution
  # ============================================================

  defp resolve_config(opts) do
    env = Application.get_env(:fleet_pilot, :forge, [])
    merged = Keyword.merge(env, opts)

    with {:ok, base_url} <- fetch_required(merged, :base_url),
         {:ok, token} <- resolve_token(merged) do
      {:ok,
       %{
         base_url: String.trim_trailing(base_url, "/"),
         token: token,
         req_options: Keyword.get(merged, :req_options, [])
       }}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:config, {:missing, key}}}
    end
  end

  defp resolve_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        case Keyword.get(opts, :token_file) || default_token_file() do
          nil ->
            {:error, {:config, :no_token_source}}

          path ->
            case File.read(path) do
              {:ok, content} -> {:ok, String.trim(content)}
              {:error, reason} -> {:error, {:config, {:token_file, path, reason}}}
            end
        end
    end
  end

  defp default_token_file do
    case System.user_home() do
      nil -> nil
      home -> Path.join(home, ".gitea_token")
    end
  end
end
