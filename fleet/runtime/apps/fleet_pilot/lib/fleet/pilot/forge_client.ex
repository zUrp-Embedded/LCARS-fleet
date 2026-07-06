defmodule Fleet.Pilot.ForgeClient do
  @moduledoc """
  Client Gitea REST API de `fleet_pilot` — la couche DOMAINE de la forge-state-machine
  (la forge EST la machine à états). Porte les ops sur issues/PR (read/write idempotentes),
  l'état de jury des PR, l'onboarding repo + sceau d'admission, et l'adaptateur credential→wire
  `as_role/2`. C'est le module injecté par le seam `:forge_client` (StepDispatcher/Poller).

  Deux couches vivent SOUS lui (ré-exportées ici pour préserver le contrat historique) :

    * `Fleet.Pilot.ForgeClient.Transport` — moteur HTTP/config/encodage/pagination + login système.
      Aucune connaissance du protocole forge. `ForgeClient` l'`import`e (`http_get`, `paginate`, …).
    * `Fleet.Pilot.ForgeProtocol` — vocabulaire PUR du wire-protocol (feature-branches, marqueurs
      route/step_run/onboard, blocs result, `system_authored?`), build+parse co-localisés. Les callers
      l'appellent DIRECTEMENT. Seul `parse_feature_branch/1` est ré-exporté ici (`defdelegate`) car
      `fleet_mcp` l'atteint via le seam `:forge_client` (évite une dep compile-time vers fleet_pilot).

  ⚠ CONTRAT CROISÉ (seam `fleet_mcp`) : ce module est l'impl RÉELLE (défaut) du behaviour
  `Fleet.MCP.PodTools.Delegation.ForgeClient` (callbacks = `create_issue/4`, `add_label/4`,
  `get_issue/3`, `list_open_pulls/2`, `parse_feature_branch/1`, `pr_review_verdicts/3`). On ne peut
  PAS l'adopter en `@behaviour` : `fleet_pilot` ne dépend pas de `fleet_mcp` et la référence compile
  créerait une arête nouvelle (`allowed_graph.yaml` rougirait). Impl duck-typée — toute évolution de
  ces 6 signatures DOIT être répercutée sur les `@callback` du behaviour (et inversement).

  ## Configuration

  Résolue à l'appel par `Transport.resolve_config/1` (cf. son moduledoc) : `:base_url`, `:token`
  (ou `:token_file`, défaut `~/.gitea_token`), `:req_options` passées à `Req`.

  ## Idempotence

  Les write-ops sont idempotentes (skip si l'état cible est déjà atteint). Ex. `add_label/4` :
  `GET issue labels + PUT label set` (un POST append créerait des doublons), re-call sur label
  présent = `{:ok, :already_present}`, zéro round-trip d'écriture.
  """

  require Logger

  alias Fleet.Pilot.ForgeProtocol
  alias Fleet.Pilot.ForgeClient.Jury
  alias Fleet.Pilot.ForgeClient.Repo

  # Plomberie tirée de Transport sous les noms historiques → les call-sites domaine restent
  # inchangés (`http_get(config, …)`, `paginate(…)`, `resolve_config(opts)`, …).
  import Fleet.Pilot.ForgeClient.Transport,
    only: [
      resolve_config: 1,
      http_get: 2,
      http_post: 3,
      http_patch: 3,
      http_delete: 2,
      paginate: 3,
      forge_bot_login: 2
    ]

  # Encodage sûr des segments d'URL (verrou path-traversal) — autorité unique UrlSafe.
  import Fleet.Pilot.ForgeClient.UrlSafe, only: [encode_seg: 1, encode_repo: 1]

  # SEUL ré-export du vocab : `parse_feature_branch/1`. `fleet_mcp` (pod_tools) l'appelle via le seam
  # `forge` (résolu runtime, défaut ce module) pour ne PAS créer de dep compile-time vers fleet_pilot —
  # le seam doit donc porter cette fonction. Le reste du vocab (`feature_branch`, `step_run_marker`,
  # `result_block`, marqueurs, `system_authored?`, `onboard_marker`) s'appelle directement sur
  # `Fleet.Pilot.ForgeProtocol` (impl + tests y vivent) ; ce module-ci ne le ré-exporte plus.
  defdelegate parse_feature_branch(head), to: ForgeProtocol

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
  Utilisé par `Fleet.Pilot.Poller` (catch-up issues sans
  `lcars-dispatched`).

  ## Returns

    * `{:ok, [issue]}` — issues filtrées, payloads bruts Gitea
    * `{:error, term()}` — propagation des erreurs HTTP/transport/config

  ## Pagination

  Limite hard-coded à 50 issues/page, 1 seule page. Pour les opérations
  catch-up, ça couvre largement la fenêtre de catch-up post-crash. Si
  le poller doit traiter +50 issues entre 2 ticks, c'est un signe que
  l'interval est trop long ou la forge en burst — sujet de tuning, pas
  une limite à lever.
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
  Liste les issues ouvertes du `repo` ASSIGNÉES À MOI (scoping multi-user forge-side). Brique du
  bail dispatch repo-serialise (compte les pipelines actifs, in-flight inclus). PAGINÉ. Délègue à
  `list_scoped_issues` — issues ET PR passent par le MÊME endpoint `/issues?type=…` (un seul code de scoping).
  """
  @spec list_open_issues(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_issues(repo, opts \\ []) when is_binary(repo) do
    list_scoped_issues(repo, "issues", opts)
  end

  # UN SEUL lister sur `/issues`, paramétré par `type` (issues|pulls) + scopé assignee FORGE-SIDE.
  # Source unique du listing/scoping (state/type/assigned_by), paginée. La forge filtre
  # (`assigned_by` — Gitea 1.26.1 marche sur /issues pour les 2 types) → le poller ne voit
  # QUE les siennes (le bail devient par-humain, cohérent N-fleets-par-humain). Le scoping vit ICI, en un
  # seul endroit — decide/dispatch_review n'ont plus à re-vérifier l'ownership.
  defp list_scoped_issues(repo, type, opts) when type in ["issues", "pulls"] do
    with {:ok, config} <- resolve_config(opts) do
      paginate(
        config,
        "/repos/#{encode_repo(repo)}/issues",
        "state=open&type=#{type}" <> assigned_by_qs(opts)
      )
    end
  end

  # Suffixe query `&assigned_by=<login>` si `opts[:assigned_by]` posé, sinon "". Pur/testable.
  @doc false
  def assigned_by_qs(opts) do
    case Keyword.get(opts, :assigned_by) do
      login when is_binary(login) and login != "" -> "&assigned_by=" <> URI.encode_www_form(login)
      _ -> ""
    end
  end

  @doc """
  Lit une issue par numéro (Gitea `GET /repos/{repo}/issues/{n}`). Lecture seule : `state`
  (open/closed), labels, assignees… Utilisé par le tool MCP `get_issue_status` (l'arch SUIT un
  issue délégué — ex. valider la livraison avant d'enchaîner). `{:error, {:http, 404, _}}` si absent.
  """
  @spec get_issue(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def get_issue(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts) do
      http_get(config, "/repos/#{encode_repo(repo)}/issues/#{number}")
    end
  end

  # ============================================================
  # Write-ops — primitives mécaniques de fin-de-step-run (la forge EST la machine à états).
  # Toutes idempotentes (skip si l'état cible est déjà atteint).
  # ============================================================

  @doc """
  Réassigne l'issue à `login` (1-assignee strict, invariant de la workflow_map). PATCH `assignees: [login]`
  remplace la liste. Idempotent : `{:ok, :already}` si `login` est déjà le seul assignee.
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

  # La POSITION workflow_map (= l'état de la machine à états) vit dans le label SCOPÉ `stage/*` (mutex
  # natif Gitea, source unique visible humain+machine), posée par `post_route` / lue par `get_route`.
  # Plus de commentaire `[lcars-route:...]` (bruit). Les verrous PLATS (`lcars-in-flight`) restent
  # non-scopés via `add_label`/`remove_label`.

  @doc """
  Poste un comment. Si `:dedup_signature` est fourni et qu'un comment **système**
  existant la contient déjà, no-op (`{:ok, :already}`) — la signature `[step_run:<role>:<sha>]` rend le
  replay idempotent. Le dédup ne fait foi QUE des comments du bot : sinon un
  user forge postant la signature en avance supprimerait le comment système (→ `count_signed_step_runs`
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
  Retire le label `label_name` (release du verrou `lcars-in-flight` en fin-de-step-run).
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
  Ferme l'issue (terminal de chaîne). PATCH `state: closed`. Idempotent côté Gitea.
  """
  @spec close_issue(String.t(), integer(), Keyword.t()) :: {:ok, :closed} | {:error, term()}
  def close_issue(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, _} <-
           http_patch(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}", %{
             state: "closed"
           }) do
      {:ok, :closed}
    end
  end

  # ============================================================
  # Repo / onboarding — DÉLÉGUÉ à `Fleet.Pilot.ForgeClient.Repo`.
  # Provisioning (create_repo/add_collaborator/add_topic/protect_branch) + sceau d'admission
  # (post_onboard_marker/admitted?) + découverte (search_repos_by_topic/repo_id). Les ops de
  # provisioning sont appelées EN DIRECT sur `ForgeClient.Repo` (par `ProjectOnboard`) ; seules les ops
  # SEAM-FACED ci-dessous sont forwardées (le module injecté par le seam reste CE module). Doc + logique
  # vivent dans `Repo` (qui dépend en retour de `create_issue`/`close_issue` du cœur pour le sceau).
  # ============================================================

  @doc "Repos découverts par topic. Voir `Fleet.Pilot.ForgeClient.Repo.search_repos_by_topic/2`."
  def search_repos_by_topic(topic, opts \\ []), do: Repo.search_repos_by_topic(topic, opts)

  @doc "Id forge numérique du repo. Voir `Fleet.Pilot.ForgeClient.Repo.repo_id/2`."
  def repo_id(repo, opts \\ []), do: Repo.repo_id(repo, opts)

  @doc "Repo admis (sceau bot-authored) ? Voir `Fleet.Pilot.ForgeClient.Repo.admitted?/3`."
  def admitted?(repo, human, opts \\ []), do: Repo.admitted?(repo, human, opts)

  @doc """
  Crée une issue sur `repo`. `opts[:assignees]` = logins, `opts[:labels]` = IDs entiers
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

      case http_post(config, "/repos/#{encode_repo(repo)}/issues", attrs) do
        {:ok, %{"number" => number}} -> {:ok, number}
        {:error, _} = err -> err
      end
    end
  end

  # ============================================================
  # Pull requests (git-native) — la PR est la surface de la phase
  # REVIEW+PROMOTE : domicile durable des verdicts de gate (review native Gitea) et
  # entonnoir unique vers `main`. Barrière : le SYSTÈME ouvre/review/merge, le pod
  # n'a jamais le token. Primitives IDEMPOTENTES (rejouables sans casser).
  # ============================================================

  @doc """
  Ouvre une pull request `head` → `base` sur `repo` (Gitea `POST /repos/{repo}/pulls`).
  IDEMPOTENT : si une PR ouverte existe déjà pour cette `head`, retourne son numéro (le
  409 Gitea n'est pas une erreur). `opts[:body]` = corps — y mettre `Closes #N` pour
  l'auto-close de l'issue au merge (la forge maintient le lien issue↔PR).

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

      case http_post(config, "/repos/#{encode_repo(repo)}/pulls", attrs) do
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
      case http_get(config, "/repos/#{encode_repo(repo)}/pulls?state=open&limit=50") do
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
      case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/requested_reviewers", %{
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
  Merge (PROMOTE) la PR `index` en **`rebase`** (Gitea `POST /repos/{repo}/pulls/{index}/merge`,
  `Do: rebase` par défaut) : rejoue les commits de la PR sur le `main` courant puis fast-forward →
  reste **LINÉAIRE** (pas de merge commit, doctrine append-only préservée) ET gère un `main` qui a
  avancé sous la PR (MULTI-ISSUE PARALLÈLE : 2 issues disjoints → 2 PR du même `main` → la 1ʳᵉ
  merge avance `main`, la 2ᵉ n'est plus FF-able mais reste mergeable → `rebase` la passe ; `fast-forward-only`
  la wedgerait à l'infini).

  **PAS de cascade FF→rebase** : une 1ʳᵉ tentative qui échoue rejette la PR en état « checking »
  (Gitea recalcule la mergeabilité de façon ASYNCHRONE), et la 2ᵉ tentative dos-à-dos tape dans cette
  fenêtre → `405 « Please try again later »` (double-appel = double-405 ; `rebase` seul
  sur une PR stable = 200). Donc UN SEUL appel, et le `405 try-again-later` est traité comme un
  **TRANSITOIRE** (retry borné `@merge_checking_retries` × `merge_retry_delay_ms`, défaut 800ms — la
  mergeabilité se stabilise en ~1 calcul). Tout autre échec (vrai conflit, pas d'approbations sous
  branch-protection) remonte tel quel (fail-loud). `opts[:method]` force un style (ex. tests).
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

  # UN appel `Do: method` ; retry borné UNIQUEMENT sur le transitoire « try again later » (mergeabilité
  # en cours de calcul côté Gitea). Toute autre erreur = définitive → remonte (fail-loud).
  defp do_merge(config, repo, index, method, delay, attempts_left) do
    # `delete_branch_after_merge` → Gitea supprime la feature-branch
    # `lcars/issue-N-role` après merge (hygiène : pas d'empilement de branches mortes). No-op si
    # branche protégée/absente ; le merge reste l'autorité (la suppression est un effet de bord).
    case http_post(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/merge", %{
           "Do" => method,
           "delete_branch_after_merge" => true
         }) do
      {:ok, _} ->
        :ok

      {:error, {:http, 405, body}} = err ->
        if attempts_left > 1 and merge_checking?(body) do
          Logger.info(
            "ForgeClient: merge_pr ##{index} mergeabilité en cours (« try again later ») → " <>
              "retry dans #{delay}ms (#{attempts_left - 1} restants)"
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

  # Transitoire Gitea : la mergeabilité d'une PR est recalculée en async (après création / push / un
  # `main` avancé) → toute tentative de merge pendant ce calcul renvoie 405 « Please try again later ».
  defp merge_checking?(body) when is_map(body),
    do: body |> Map.get("message", "") |> String.downcase() |> String.contains?("try again later")

  defp merge_checking?(_), do: false

  @doc """
  Liste les PR OUVERTES du `repo` ASSIGNÉES À MOI (scoping multi-user forge-side), shape PR
  COMPLÈTE : `number`, `head.ref` (feature-branch `lcars/issue-N-role`), `head.sha`, `requested_reviewers`,
  `labels`. PAGINÉ. Brique du dispatch juge PR-driven.

  Hybride (Gitea 1.26.1) : `/pulls` n'a PAS `assigned_by`, mais `/issues?type=pulls&assigned_by`
  filtre l'assignee (en rendant une shape ISSUE, sans head/requested_reviewers). Donc on FILTRE via
  `list_scoped_issues(type: pulls)` — MÊME code de scoping/pagination que les issues — puis on récupère la
  shape PR complète via `get_pull/3`, 1 par numéro. Le scoping reste 100% forge-side, comme les issues.
  """
  @spec list_open_pulls(String.t(), Keyword.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_pulls(repo, opts \\ []) when is_binary(repo) do
    with {:ok, pr_issues} <- list_scoped_issues(repo, "pulls", opts) do
      pr_issues |> Enum.map(& &1["number"]) |> fetch_pulls(repo, opts)
    end
  end

  # Récupère la shape PR complète (head/head.sha/requested_reviewers) pour chaque numéro filtré. Fail-fast :
  # une erreur sur une PR arrête tout (on ne dispatche pas sur une vue partielle, comme la pagination).
  defp fetch_pulls(numbers, repo, opts) do
    numbers
    |> Enum.reduce_while({:ok, []}, fn n, {:ok, acc} ->
      case get_pull(repo, n, opts) do
        {:ok, pr} -> {:cont, {:ok, [pr | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, prs} -> {:ok, Enum.reverse(prs)}
      err -> err
    end
  end

  @doc "GET une PR unique → shape complète (head/head.sha/requested_reviewers). Brique de list_open_pulls."
  @spec get_pull(String.t(), integer(), Keyword.t()) :: {:ok, map()} | {:error, term()}
  def get_pull(repo, number, opts \\ []) when is_binary(repo) and is_integer(number) do
    with {:ok, config} <- resolve_config(opts),
         do: http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{number}")
  end

  # ============================================================
  # Jury PR — DÉLÉGUÉ à `Fleet.Pilot.ForgeClient.Jury`.
  # Concern autonome (lecture des reviews, zéro couplage au cœur). Le module injecté par le seam
  # `:forge_client` reste CE module → on FORWARDE (wrappers explicites : `defdelegate` ne gère pas les
  # args par défaut). Doc + logique (commit-scoping, jury volatil) vivent dans `Jury`.
  # ============================================================

  @doc "Verdicts décisifs par juge d'une PR. Voir `Fleet.Pilot.ForgeClient.Jury.pr_review_verdicts/3`."
  def pr_review_verdicts(repo, index, opts \\ []), do: Jury.pr_review_verdicts(repo, index, opts)

  @doc "État de jury (verdicts + SET du jury) d'une PR. Voir `Fleet.Pilot.ForgeClient.Jury.pr_review_state/3`."
  def pr_review_state(repo, index, opts \\ []), do: Jury.pr_review_state(repo, index, opts)

  @doc "Feedback des REQUEST_CHANGES en vigueur. Voir `Fleet.Pilot.ForgeClient.Jury.change_request_feedback/3`."
  def change_request_feedback(repo, index, opts \\ []),
    do: Jury.change_request_feedback(repo, index, opts)

  @doc "Compte les rounds de rework. Voir `Fleet.Pilot.ForgeClient.Jury.count_change_request_rounds/3`."
  def count_change_request_rounds(repo, index, opts \\ []),
    do: Jury.count_change_request_rounds(repo, index, opts)

  # put_file / get_file → `Fleet.Pilot.ForgeClient.Files` (concern autonome, appelé en direct, pas via
  # le seam — `IncidentRegistry` les injecte comme `:get_file_fun`/`:put_file_fun`). Pas de forwarder ici.

  defp comment_signed?(config, repo, issue_number, sig, opts) do
    # Paginé — un comment système signé au-delà de 50 ne doit pas échapper au dédup (sinon
    # double-post au replay). Une page de forme inattendue rend `{:error, …}` (et non un
    # `{:ok, acc}` tronqué) → tombe dans le `_ -> false` (pas de signature trouvée = on poste, fail-safe
    # dédup : au pire un double-post au replay, jamais une suppression silencieuse d'un marqueur).
    case paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      {:ok, comments} when is_list(comments) ->
        # Le dédup garde une ÉCRITURE système → ne fait foi que des comments
        # du bot. Sinon un user forge poste la signature en avance → le comment système est skipé →
        # `count_signed_step_runs` sous-compte (budget anti-runaway sur-permissif). Bot irrésoluble →
        # fail-OPEN (dédup non filtré) : au pire un comment dupliqué au replay, jamais une suppression
        # silencieuse d'un marqueur load-bearing.
        trusted =
          cond do
            # Marqueur NON load-bearing (ex. `[merge:pr-N]`, posté par le compte de RÔLE
            # gatekeeper et non le bot système) → dédup AUTHOR-AGNOSTIC. Le filtre bot-only ne
            # protège QUE les marqueurs comptés (`[step_run:role:sha]` → count_signed_step_runs) : un comment de
            # sceau gatekeeper échapperait sinon au dédup bot-only (double-post au replay/retry).
            Keyword.get(opts, :dedup_any_author, false) ->
              comments

            true ->
              case forge_bot_login(config, opts) do
                {:ok, bot} -> Enum.filter(comments, &ForgeProtocol.system_authored?(&1, bot))
                {:error, _} -> comments
              end
          end

        Enum.any?(trusted, fn c -> String.contains?(c["body"] || "", sig) end)

      _ ->
        false
    end
  end

  # ============================================================
  # Position workflow_map — 2 labels SCOPÉS sur l'issue (la forge EST la machine à états).
  # Remplace l'ancien commentaire `[lcars-route:<map>:<step>]` (bruit dans le fil humain) :
  #   `stage/<step>` : l'étape COURANTE, mobile (mutex natif Gitea : poser une étape retire la précédente).
  #   `wfmap/<map>`  : QUELLE map suit cette issue, posé une fois (mutex : une seule map par issue).
  # Les deux VISIBLES (coup d'œil humain), lus directement (pas de scan de commentaires), infalsifiables
  # via le verrou d'écriture WS1 (rôles en issues:read) : irreprésentabilité > filtrage-à-la-lecture.
  # Le map vit PAR-ISSUE (donnée) — PAS un défaut global codé : deux issues peuvent suivre deux maps
  # (multi-map, cf. tests gkchain/poc-mini). Aucun `default` ici : un défaut de map n'a qu'UN lieu
  # légitime, l'onboard d'une issue routeless (`StepDispatcher.ensure_workflow_map_or_onboard`).
  # ============================================================

  @stage_prefix "stage/"
  @wfmap_prefix "wfmap/"

  @doc """
  Pose la position = `wfmap/<pipeline>` (quelle map, idempotent) + `stage/<step>` (l'étape courante,
  mutex : retire l'ancien `stage/*`). Les deux scopés `exclusive` (cf. `ensure_org_label`).
  `{:ok, :posted}` si l'étape a bougé, `{:ok, :already}` si déjà à cette étape, `{:error, _}` sinon.
  """
  @spec post_route(String.t(), integer(), String.t(), String.t(), Keyword.t()) ::
          {:ok, :posted | :already} | {:error, term()}
  def post_route(repo, issue_number, pipeline, step, opts \\ [])
      when is_binary(pipeline) and is_binary(step) do
    with {:ok, _} <- add_label(repo, issue_number, wfmap_label(pipeline), opts) do
      case add_label(repo, issue_number, stage_label(step), opts) do
        {:ok, :added} -> {:ok, :posted}
        {:ok, :already_present} -> {:ok, :already}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Lit la position = `{:ok, {map, step}}` depuis les labels `wfmap/<map>` + `stage/<step>` de l'issue.
  `:none` si l'un manque (issue routeless, ou demi-état → ré-onboardée par le caller). `{:error, _}` sur
  échec HTTP/config. Le map vient de la DONNÉE (label `wfmap/*`), jamais d'un défaut codé — pas
  d'invention silencieuse d'un map (canon : ambiguïté rejetée, pas de fallback métier caché). La
  CONFIANCE vient du verrou d'écriture WS1 (seul `lcars-system` pose les labels) : irreprésentabilité >
  filtrage-à-la-lecture. Modèle de menace : un rôle compromis qui poserait un faux `stage/*` = nuke&redeploy.
  """
  @spec get_route(String.t(), integer(), Keyword.t()) ::
          {:ok, {String.t(), String.t()}} | :none | {:error, term()}
  def get_route(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, labels} <- get_issue_labels(config, repo, issue_number) do
      case {current_wfmap(labels), current_stage(labels)} do
        {map, step} when is_binary(map) and is_binary(step) -> {:ok, {map, step}}
        _ -> :none
      end
    end
  end

  # Builders des labels de position (source-unique des littéraux avec `@stage_prefix`/`@wfmap_prefix`).
  defp stage_label(step) when is_binary(step), do: @stage_prefix <> step
  defp wfmap_label(map) when is_binary(map), do: @wfmap_prefix <> map

  # Étape courante = valeur du label `stage/<step>` (au plus un : mutex). Map = valeur du `wfmap/<map>`.
  defp current_stage(labels), do: label_value(labels, @stage_prefix)
  defp current_wfmap(labels), do: label_value(labels, @wfmap_prefix)

  # Valeur (suffixe) du 1er label scopé `<prefix><valeur>` de l'issue, nil si aucun. Générique aux 2 scopes.
  defp label_value(labels, prefix) when is_list(labels) do
    Enum.find_value(labels, fn label ->
      name = label["name"]

      if is_binary(name) and String.starts_with?(name, prefix),
        do: String.replace_prefix(name, prefix, "")
    end)
  end

  @doc """
  Compte les comments portant un marqueur de step_run signé `[step_run:<role>:<sha>]`
  (posés par `StepRunCompleter` à chaque fin-de-step-run). Sert de compteur **forge-natif**
  au bound anti-runaway du rebond de gate : combien de step_runs ont déjà été
  joués sur l'issue. Monotone (les comments ne sont pas retirés), idempotent à lire.

  `{:error, _}` sur échec HTTP/config — le caller NE rebondit PAS à l'aveugle si le
  budget n'est pas vérifiable (un rebond non vérifiable pourrait boucler).

  PAGINÉ : même si le budget de rework (`nb_steps * (max_rounds+1)`) reste en
  général sous 50, le compteur est source-de-vérité du bound anti-runaway — un step_run signé
  perdu au-delà de 50 sous-compterait le budget (sur-permissif). On lit donc TOUTES les pages.
  """
  @spec count_signed_step_runs(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_signed_step_runs(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      # Compter SEULEMENT les step_runs signés par le SYSTÈME — sinon un user forge forge des
      # `[step_run:role:sha]` pour gonfler le compteur et faire TRIPPER le budget anti-runaway (DoS rework).
      # Bot irrésoluble → {:error} (via le with) : le caller NE rebondit PAS sur un budget non vérifiable.
      count =
        comments
        |> Enum.filter(&ForgeProtocol.system_authored?(&1, bot))
        |> Enum.map(& &1["body"])
        |> Enum.count(&ForgeProtocol.step_run_marker?/1)

      {:ok, count}
    end
  end

  @doc """
  Extrait le dernier bloc ` ```result ` posté dans un comment de step_run — le `result_K`
  gravé par `StepRunCompleter` quand le step avance vers un gatekeeper. Sert
  à `StepDispatcher` pour donner au pod gatekeeper **quoi juger** dans son brief
  (option B : pas de clone de branche). `:none` si aucun ; `{:error, _}` HTTP/config.
  """
  @spec get_predecessor_result(String.t(), integer(), Keyword.t()) ::
          {:ok, map()} | :none | {:error, term()}
  def get_predecessor_result(repo, issue_number, opts \\ []) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, bot} <- forge_bot_login(config, opts),
         {:ok, comments} when is_list(comments) <-
           paginate(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/comments", "") do
      # Le bloc ```result nourrit le BRIEF DE JUGEMENT du gatekeeper. Ne
      # l'extraire QUE de comments SYSTÈME — sinon un user forge injecte ce que le juge évalue.
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

  # ADD un label par NOM (POST = ajoute sans remplacer l'existant). Gitea résout le nom contre les
  # labels REPO **et ORG** côté serveur (`IssueLabelsOption.labels` = « strings representing label
  # names », doc swagger) → plus de résolution repo-id côté client (qui ratait les org-labels). Les
  # labels-verrous du wire-protocol vivent au niveau ORG `fleet` (config fleet, une fois, pas par-repo).
  #
  # SELF-HEAL : Gitea ignore EN SILENCE un nom de label qui n'existe NI au repo NI à l'org (POST
  # 200, mais le label n'est PAS posé) → le verrou protocole serait fantôme → boucle de re-dispatch
  # (ex. `lcars-awaits-arch` absent de l'org). On ne se fie donc PAS au seul 200 : on VÉRIFIE
  # que le label est dans la réponse ; absent → on le CRÉE (org du repo) puis on ré-essaie ; toujours
  # absent → fail-loud `{:label_not_added}` (jamais un :ok menteur). Plus de dépendance à des labels
  # créés à la main.
  defp add_issue_label(config, repo, issue_number, label_name) do
    case post_issue_label(config, repo, issue_number, label_name) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        with :ok <- ensure_org_label(config, repo, label_name),
             {:ok, true} <- post_issue_label(config, repo, issue_number, label_name) do
          :ok
        else
          _ -> {:error, {:label_not_added, label_name}}
        end

      {:error, _} = err ->
        err
    end
  end

  # POST le label ET vérifie qu'il est réellement posé : la réponse Gitea = les labels de l'issue après
  # ajout. Un nom inconnu est ignoré en silence (200 sans le label) → `{:ok, false}` (à compenser).
  defp post_issue_label(config, repo, issue_number, label_name) do
    case http_post(config, "/repos/#{encode_repo(repo)}/issues/#{issue_number}/labels", %{
           labels: [label_name]
         }) do
      {:ok, body} when is_list(body) -> {:ok, Enum.any?(body, &(&1["name"] == label_name))}
      {:ok, _non_list} -> {:ok, false}
      {:error, _} = err -> err
    end
  end

  # Crée le label protocole manquant au niveau de l'ORG du repo (convention LCARS : les labels
  # `lcars-*` sont des labels d'ORG, partagés par tous les repos de la fleet). Couleur/
  # description par défaut (le NOM porte le protocole ; la couleur est cosmétique). Tolérant : un échec
  # (créé en concurrence, ou repo non-org) → `:ok` — c'est le re-POST + sa vérif qui tranchent (sinon
  # le fail-loud d'`add_issue_label` remonte).
  defp ensure_org_label(config, repo, label_name) do
    org = repo |> String.split("/") |> List.first()

    # Un label SCOPÉ (nom `scope/valeur`, contient "/") est créé MUTUELLEMENT EXCLUSIF (`exclusive:true`) :
    # Gitea retire l'ancien `scope/*` de l'issue quand on en pose un nouveau (vérifié forge 1.26.1, niveau
    # org ET repo, par NOM). C'est le mécanisme du `stage/*` (position workflow_map = machine à états
    # visible) : irreprésentabilité native (jamais 2 étapes). Les verrous PLATS (`lcars-*`) non-exclusifs.
    body = %{
      name: label_name,
      exclusive: String.contains?(label_name, "/"),
      color: label_color(label_name),
      description: "label protocole lcars (auto-cree, F-E5)"
    }

    case http_post(config, "/orgs/#{encode_seg(org)}/labels", body) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  # Couleur cosmétique (le NOM porte le protocole). Les `stage/*` reçoivent une teinte par étape pour le
  # coup d'œil humain (bleu→ambre→violet→vert = brief-review→build→review→merged) ; le reste, gris neutre.
  defp label_color("stage/brief-review"), do: "#4a90d9"
  defp label_color("stage/build"), do: "#e08e0b"
  defp label_color("stage/review"), do: "#8e44ad"
  defp label_color("stage/merged"), do: "#2e9e5b"
  defp label_color(_), do: "#ededed"

  # ============================================================
  # Identite forge — adaptateur credential -> wire (token de role)
  # ============================================================

  @doc """
  Injecte le token du compte de RÔLE (`role`) dans `forge_opts`, sous la clé `:token` que
  `resolve_config`/`resolve_token` relisent → le SYSTÈME poste/merge EN SON NOM sur la forge (avatar +
  traça honnête, au lieu du compte système). C'est l'adaptateur UNIQUE credential→wire — source unique
  partagée par `StepRunCompleter`, `StepDispatcher` et les sceaux gatekeeper (le writer du `:token` est ici,
  collé à son reader). `Fleet.Credentials.RoleToken` fournit le token, `forge_opts[:token]` le porte
  jusqu'à la requête. Rôle vide/absent OU token absent/illisible/vide → `forge_opts` inchangé → fallback
  sur le token (système) déjà présent ; `RoleToken.token/1` émet un `Logger.warning` sur ce dégradé, donc
  observable côté appelant. Le pod ne poste jamais : c'est le système qui poste avec le token de rôle,
  jamais le pod (forge-aveugle).
  """
  @spec as_role(keyword(), String.t() | nil) :: keyword()
  def as_role(forge_opts, role) when is_binary(role) and role != "" do
    case Fleet.Credentials.RoleToken.token(role) do
      t when is_binary(t) -> Keyword.put(forge_opts, :token, t)
      _ -> forge_opts
    end
  end

  def as_role(forge_opts, _role), do: forge_opts
end
