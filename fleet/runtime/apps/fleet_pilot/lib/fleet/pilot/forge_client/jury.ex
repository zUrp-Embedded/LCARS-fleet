defmodule Fleet.Pilot.ForgeClient.Jury do
  @moduledoc """
  Lecture de l'**état de jury** d'une PR (reviews natives Gitea) — sous-domaine de `Fleet.Pilot.ForgeClient`.
  Concern autonome : il ne lit QUE `GET .../pulls/{index}/reviews` et en dérive verdicts/jury/feedback ;
  il n'appelle aucune autre op forge (zéro couplage au cœur issues/PR). `ForgeClient` forwarde ces
  fonctions (le module injecté par le seam `:forge_client` reste `ForgeClient` ; l'implémentation vit ici).

  La subtilité du domaine — pourquoi ce n'est PAS trivial — est le **commit-scoping** et le fait que
  `requested_reviewers` de Gitea est VOLATIL : la source de vérité du jury est la liste des review-records,
  pas le champ requested. Détails dans chaque `@doc`.
  """

  import Fleet.Pilot.ForgeClient.Transport, only: [resolve_config: 1, http_get: 2, encode_repo: 1]

  @doc """
  Verdict de review **PAR juge** d'une PR (Gitea `GET /repos/{repo}/pulls/{index}/reviews`) : la
  DERNIÈRE review décisive non-dismissed de CHAQUE reviewer, clé = login **downcasé**.

  **Pourquoi par-juge et pas `requested_reviewers`** : Gitea 1.26 ne vide PAS `requested_reviewers`
  quand un juge a reviewé, et la DELETE est un no-op sur un reviewer déjà actif → on
  ne peut PAS s'appuyer dessus pour savoir « qui reste à juger ». La SOURCE DE VÉRITÉ = la liste des
  reviews : un juge a un **verdict décisif** ssi sa dernière review non-dismissed est APPROVED ou
  REQUEST_CHANGES. Le poller dispatch un juge demandé qui n'a PAS encore de verdict, et tranche
  (merge/rework) quand tous les demandés en ont un.

  **Commit-scoping (`:head_sha`)** : un verdict ne vaut que pour le COMMIT qu'il a jugé. Passer
  `head_sha: pr.head.sha` (chemin prod) → seules les reviews `commit_id == head_sha` comptent ; une review
  sur un commit antérieur est PÉRIMÉE (le code n'existe plus). Crucial pour le REQUEST_CHANGES : Gitea ne
  le dismisse JAMAIS au push (≠ approbations stale, dismissées par branch-protection) — sans scoping, un
  REQUEST_CHANGES périmé reste « actif », son juge n'est jamais re-dispatché (il a déjà un verdict) et la
  PR bouclerait en rework infini. Le scoping le rend `pending` → re-jugé sur le code courant.
  Les reviews COMMENT/PENDING/REQUEST_REVIEW ne sont PAS décisives (ignorées).

  ## Returns
    * `{:ok, %{"qualifier" => :approved, "reviewer" => :changes_requested, ...}}` — login(↓) → verdict
    * `{:ok, %{}}` — aucune review décisive
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec pr_review_verdicts(String.t(), integer(), Keyword.t()) ::
          {:ok, %{optional(String.t()) => :approved | :changes_requested}} | {:error, term()}
  def pr_review_verdicts(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    # Projection « verdicts seuls » de `pr_review_state` (factorisé : un seul fetch, une seule logique de
    # scoping/dernière-review). Conservé pour les callers qui n'ont pas besoin du SET du jury (pod_tools).
    with {:ok, %{verdicts: verdicts}} <- pr_review_state(repo, index, opts), do: {:ok, verdicts}
  end

  @doc """
  État de jury d'une PR en UN fetch (`GET .../pulls/{index}/reviews`) : `verdicts` (décisifs par juge,
  commit-scopés via `:head_sha` — cf. `pr_review_verdicts`) ET `reviewers` (le SET du jury).

  **Le SET du jury ne se lit PAS de `pr.requested_reviewers`** : ce champ est VOLATIL (Gitea
  l'altère de façon non fiable — un juge peut en DISPARAÎTRE sans avoir voté, ce qui ferait merger sur
  demi-jury). Source STABLE = les review-records, qui persistent : un `REQUEST_REVIEW` =
  « ce juge a été demandé » ; un `APPROVED`/`REQUEST_CHANGES` = « il a voté ». Le caller (`dispatch_review`)
  unionne avec `requested_reviewers` (défensif) et calcule `pending = jury -- verdicts` → un juge
  jamais-voté reste `pending` (spawné), JAMAIS sauté.

  ## Returns
    * `{:ok, %{verdicts: %{login↓ => :approved | :changes_requested}, reviewers: [login↓]}}`
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec pr_review_state(String.t(), integer(), Keyword.t()) ::
          {:ok,
           %{
             verdicts: %{optional(String.t()) => :approved | :changes_requested},
             reviewers: [String.t()]
           }}
          | {:error, term()}
  def pr_review_state(repo, index, opts \\ []) when is_binary(repo) and is_integer(index) do
    head_sha = Keyword.get(opts, :head_sha)

    with {:ok, config} <- resolve_config(opts),
         {:ok, reviews} when is_list(reviews) <-
           http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews") do
      {:ok,
       %{verdicts: verdicts_by_reviewer(reviews, head_sha), reviewers: jury_reviewers(reviews)}}
    else
      {:ok, _non_list} -> {:ok, %{verdicts: %{}, reviewers: []}}
      {:error, _} = err -> err
    end
  end

  # Le SET du jury = tout login ayant un review-record « de jury » : demandé (`REQUEST_REVIEW`) OU
  # ayant voté (`APPROVED`/`REQUEST_CHANGES`). Exclut `COMMENT`/`PENDING` (bruit non-juge). Source STABLE
  # (les records persistent) vs `requested_reviewers` volatil → un juge tombé du champ sans voter reste
  # dans le jury → `pending` → spawné, plus de merge sur demi-jury.
  defp jury_reviewers(reviews) do
    reviews
    |> Enum.filter(&(&1["state"] in ["REQUEST_REVIEW", "APPROVED", "REQUEST_CHANGES"]))
    |> Enum.map(&(get_in(&1, ["user", "login"]) |> to_string() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Dernière review décisive PAR reviewer (login downcasé → verdict atom). Gitea liste par ordre de
  # création → `List.last` d'un groupe = la review EN VIGUEUR de ce reviewer. Quand `head_sha` est fourni
  # (chemin prod, posé par `dispatch_review` depuis `pr.head.sha`), un verdict est **COMMIT-SCOPÉ** : seul
  # celui posé sur le commit COURANT (`commit_id == head_sha`) compte ; une review sur un commit antérieur
  # est PÉRIMÉE — le code jugé n'existe plus, le juge doit re-juger. Indispensable car Gitea ne dismisse
  # PAS un REQUEST_CHANGES au push (seules les approbations stale via branch-protection le sont) : sans ce
  # filtre, un REQUEST_CHANGES périmé qui n'est jamais re-dispatché bloque la PR pour TOUJOURS.
  defp verdicts_by_reviewer(reviews, head_sha) do
    reviews
    |> Enum.reject(&Map.get(&1, "dismissed", false))
    |> Enum.filter(&(&1["state"] in ["APPROVED", "REQUEST_CHANGES"]))
    |> reject_stale_reviews(head_sha)
    |> Enum.group_by(&(get_in(&1, ["user", "login"]) |> to_string() |> String.downcase()))
    |> Map.new(fn {login, revs} -> {login, decisive_verdict(List.last(revs)["state"])} end)
  end

  # `head_sha == nil` (appelants bas-niveau / legacy) → pas de scoping. Sinon : strict `commit_id == head`.
  defp reject_stale_reviews(reviews, nil), do: reviews

  defp reject_stale_reviews(reviews, head_sha),
    do: Enum.filter(reviews, &(&1["commit_id"] == head_sha))

  defp decisive_verdict("APPROVED"), do: :approved
  defp decisive_verdict("REQUEST_CHANGES"), do: :changes_requested

  @doc """
  Feedback des reviews REQUEST_CHANGES en vigueur d'une PR (Gitea `GET .../pulls/{index}/reviews`),
  pour nourrir le **rework** du producteur. Renvoie la DERNIÈRE review REQUEST_CHANGES par reviewer
  avec son `body` — le verdict structuré gravé par le juge (`reason`/`details`/`chain`, via
  `HopConsumer.judge_review_body`). Sans ce body, le `rework_mandate` dit « corrige selon la review »
  SANS le contenu de la review → l'engineer devine à l'aveugle (famine d'info, DOUBLE :
  jumeau de l'`outputs: {}` du juge ; sans le body l'eng rend `blocked_dep` plutôt que
  deviner). Pas de commit-scoping ici : on veut le DERNIER feedback par reviewer (`List.last`), pas
  un verdict décisif courant (le rework s'exécute AVANT le prochain push, le REQUEST_CHANGES porte
  sur le head courant). Les reviews sans body (verdict générique) sont écartées (rien d'actionnable).

  ## Returns
    * `{:ok, [%{"login" => l, "body" => b}]}` — une entrée par reviewer ayant un REQUEST_CHANGES avec substance
    * `{:ok, []}` — aucun REQUEST_CHANGES avec body actionnable
    * `{:error, term()}` — HTTP/transport/config
  """
  @spec change_request_feedback(String.t(), integer(), Keyword.t()) ::
          {:ok, [%{optional(String.t()) => String.t()}]} | {:error, term()}
  def change_request_feedback(repo, index, opts \\ [])
      when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, reviews} when is_list(reviews) <-
           http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews") do
      {:ok, change_requests_by_reviewer(reviews)}
    else
      {:ok, _non_list} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  @doc """
  Compte les rounds de REWORK déjà déclenchés sur une PR = nb de reviews `REQUEST_CHANGES`
  non-dismissed (Gitea `GET .../pulls/{index}/reviews`). Chaque round (juge demande des changements →
  l'eng re-pousse → re-review) ajoute une review REQUEST_CHANGES → le compteur est **forge-natif** et
  MONOTONE (les reviews persistent), comme `count_signed_hops` pour le rebond de gate. Sert au frein
  anti-churn du chemin PR-review (`StageDispatcher.dispatch_rework`) : au-delà du budget → escalade arch.

  Pas de commit-scoping : on veut l'HISTORIQUE des rounds (tous commits), pas le verdict courant.

  `{:error, _}` sur échec HTTP/config — le caller NE re-spawn PAS à l'aveugle si le budget n'est pas
  vérifiable (un re-spawn non borné pourrait churner), symétrique de `count_signed_hops`.
  """
  @spec count_change_request_rounds(String.t(), integer(), Keyword.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_change_request_rounds(repo, index, opts \\ [])
      when is_binary(repo) and is_integer(index) do
    with {:ok, config} <- resolve_config(opts),
         {:ok, reviews} when is_list(reviews) <-
           http_get(config, "/repos/#{encode_repo(repo)}/pulls/#{index}/reviews") do
      count =
        reviews
        |> Enum.reject(&Map.get(&1, "dismissed", false))
        |> Enum.count(&(&1["state"] == "REQUEST_CHANGES"))

      {:ok, count}
    else
      {:ok, _non_list} -> {:ok, 0}
      {:error, _} = err -> err
    end
  end

  # Dernier REQUEST_CHANGES PAR reviewer (login → body). Même tri que `verdicts_by_reviewer` (ordre de
  # création Gitea → `List.last` = la review en vigueur), filtré aux REQUEST_CHANGES avec un body non-vide.
  defp change_requests_by_reviewer(reviews) do
    reviews
    |> Enum.reject(&Map.get(&1, "dismissed", false))
    |> Enum.filter(&(&1["state"] == "REQUEST_CHANGES"))
    |> Enum.group_by(&(get_in(&1, ["user", "login"]) |> to_string() |> String.downcase()))
    |> Enum.map(fn {login, revs} ->
      %{"login" => login, "body" => (List.last(revs)["body"] || "") |> to_string()}
    end)
    |> Enum.reject(&(String.trim(&1["body"]) == ""))
  end
end
