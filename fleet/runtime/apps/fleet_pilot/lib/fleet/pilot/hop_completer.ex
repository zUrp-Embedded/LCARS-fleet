defmodule Fleet.Pilot.HopCompleter do
  @moduledoc """
  Primitive de **fin-de-hop** (DN `orchestration/forge-state-machine.md` §5).
  Quand un pod (stage courant) a terminé, le **SYSTÈME** — pas le pod, qui n'a
  ni token ni outil forge (barrière §4) — applique la transition vers le stage
  suivant. C'est la pièce qui REMPLACE le chaînage inter-stage de l'Executor
  (RAM) par une séquence forge-driven idempotente.

  ## Séquence ordonnée idempotente (§5)

  L'atomicité est impossible (Gitea n'a pas de transaction ; un hop = ~5
  écritures HTTP). On la remplace par un ORDRE où le trigger du poller (PATCH
  assignee) est l'**avant-dernier** et le verrou est levé en **dernier** :

    1. **Commit + push livrable** — délégué à `Deliverable.publish` (O5 : gate
       I-CBC F-03/F-01/F-02 + push borné). Indissociables : le commit local seul
       n'est pas vu par la forge. Retourne le `commit_sha` qui signe le hop.
    2. **Comment signé** `[hop:<role>:<sha>]` — dédup par signature (replay-safe).
       *(Ancienne étape 3 « PATCH `state:*` » RETIRÉE — #5.2 D4 : l'état vit dans la route-comment,
       pas dans un label `state:*`. Les n° de step suivants gardent leur mapping DN §5.)*
    4. **Routage du stage suivant** :
         * `next_assignee` présent (multi-stage) → `set_assignee(next)` ; le
           poller ne verra le suivant que quand 1-3 sont OK. **(branche A2 — le
           calcul de `next_assignee` depuis la carte est hors A1.)**
         * `next_assignee == nil` (1-stage / terminal) → `close_issue`.
    5. **Retire `lcars-in-flight`** — en DERNIER : le poller ne re-spawn le
       suivant que quand TOUT est fini.

  **Garantie crash** : un crash à n'importe quelle étape laisse le verrou posé
  (sauf après 5) → le poller ne re-spawn pas ; la recovery (§7) rejoue la
  séquence, les étapes faites skippent (write-ops idempotentes + dédup comment +
  push idempotent). Pas de double-livrable ni double-comment.

  ## Seams

  `:deliverable` (défaut `Fleet.Pipeline.Deliverable`), `:forge_client` (défaut
  `Fleet.Pilot.ForgeClient`) — stubés en test. `:deliverable_opts` quand le hop
  produit un livrable git ; absent/`nil` = pas de livrable git (ex. verdict de
  juge en mode payload — le `hop_sha` est alors fourni explicitement).
  """

  require Logger

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.Labels

  # F072 : vocabulaire protocole = source unique Fleet.Pilot.Labels.
  @in_flight_label Labels.in_flight()

  @typedoc """
  Décrit la fin-de-hop d'un rôle sur une issue.

    * `:repo` / `:issue_number` — cible forge (obligatoires)
    * `:role` — le rôle qui vient de finir (signe le comment)
    * `:deliverable_opts` — opts passés tel quel à `Deliverable.publish/1`
      (mode/workspace/base_sha/remote/target_branch/...). `nil` = pas de
      livrable git ; alors `:hop_sha` requis.
    * `:hop_sha` — override de la signature de hop (défaut = commit_sha publié)
    * `:next_assignee` — login du rôle suivant (carte) ; `nil` = terminal → close
    * `:comment_body` — corps lisible du comment (la signature machine est
      toujours ajoutée) ; défaut généré
  """
  @type hop :: %{
          required(:repo) => String.t(),
          required(:issue_number) => integer(),
          required(:role) => String.t(),
          optional(:deliverable_opts) => map() | nil,
          optional(:hop_sha) => String.t(),
          optional(:next_assignee) => String.t() | nil,
          optional(:comment_body) => String.t()
        }

  @doc """
  Applique la séquence de fin-de-hop §5. Idempotente sur replay.

  `opts` : seams `:deliverable` / `:forge_client` / `:forge_opts`.

  Retourne `{:ok, :completed}` (terminal → issue fermée) | `{:ok, :reassigned}`
  (multi-stage → assignee suivant posé) | `{:error, {step, reason}}`.
  """
  @spec complete(hop(), keyword()) ::
          {:ok, :completed | :reassigned} | {:error, {atom(), term()}}
  def complete(hop, opts \\ []) when is_map(hop) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Pipeline.Deliverable)
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    repo = Map.fetch!(hop, :repo)
    n = Map.fetch!(hop, :issue_number)
    role = Map.fetch!(hop, :role)

    with {:ok, sha} <- step1_publish(hop, deliverable),
         {:ok, _} <- step2_comment(forge, repo, n, role, sha, hop, forge_opts),
         {:ok, routed} <- step4_route(forge, repo, n, hop, forge_opts),
         {:ok, _} <- step5_unlock(forge, repo, n, forge_opts) do
      Logger.info("HopCompleter: #{repo}##{n} role=#{role} sha=#{sha} → #{routed}")

      {:ok, routed}
    end
  end

  @awaits_arch_label Labels.awaits_arch()

  @doc """
  Fin-de-hop ALTERNATIVE (A2.3b, DN `gatekeeper-forge-encoding-v2` §3/§6) : un verdict
  gatekeeper **humain** (`escalate_user`/`halt_wait_input`/`redirect`/absent/invalide).
  Le SYSTÈME pose `lcars-awaits-arch` + retire le verrou ; NE close PAS, NE reassign PAS.
  L'issue attend une action humaine **via l'arch** (`convention-tickets-gitea-v2` §7/§8) ;
  le poller la **SKIP** (`StageDispatcher.decide` → `:awaits_arch`).

  Pas de livrable git ici (le verdict vit dans le comment signé ; `verdict.json` =
  item `submit_result` séparé). Ordre : comment → `lcars-awaits-arch` → unlock (DERNIER,
  même principe §5 : un crash laisse le verrou → poller skip → recovery rejoue,
  idempotent via dédup comment + add/remove label idempotents).

  `hop` : `:repo`, `:issue_number`, `:role`, `:decision`. Returns `{:ok, :awaiting_arch}`
  | `{:error, {:await_arch, reason}}`.
  """
  @spec await_arch(map(), keyword()) :: {:ok, :awaiting_arch} | {:error, {:await_arch, term()}}
  def await_arch(hop, opts \\ []) when is_map(hop) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(hop, :repo)
    n = Map.fetch!(hop, :issue_number)
    role = Map.fetch!(hop, :role)
    decision = Map.get(hop, :decision)

    signature = "[hop:#{role}:await:#{decision}]"

    # `:comment_body` (optionnel) = trace fournie par l'appelant (ex. HopConsumer B porte le
    # verdict gatekeeper attribué + halt_invalid distingué). Absent → corps par défaut.
    lead =
      Map.get(hop, :comment_body) ||
        "Verdict du juge **#{role}** : `#{inspect(decision)}`."

    # #5.2 — ADRESSÉ à l'arch (le sas unique vers l'humain ; l'humain n'a pas d'autre canal vers la fleet).
    # L'arch reprend le mandat (corrige + re-soumet) ou tranche avec son humain. PAS de re-assign (assignee
    # = humain owner, DN §1) : l'arch query son inbox `lcars-awaits-arch` ; l'issue reste hors-dispatch.
    body =
      "**Architecte** (auteur du mandat) — " <>
        lead <>
        "\n\nReprends ce mandat : corrige-le puis re-soumets (relance le cycle), ou tranche avec ton humain " <>
        "(il n'a pas d'autre canal vers la fleet que toi). L'issue reste hors-dispatch tant que " <>
        "`lcars-awaits-arch` est posé.\n\n" <> signature

    with {:ok, _} <-
           forge.post_comment(repo, n, body, Keyword.put(forge_opts, :dedup_signature, signature)),
         {:ok, _} <- forge.add_label(repo, n, @awaits_arch_label, forge_opts),
         {:ok, _} <- forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      Logger.info(
        "HopCompleter: #{repo}##{n} role=#{role} → awaiting_arch (decision=#{inspect(decision)})"
      )

      {:ok, :awaiting_arch}
    else
      {:error, reason} -> {:error, {:await_arch, reason}}
    end
  end

  @doc """
  **PR-natif (Corr.3, BL-044)** — livraison engineer → PR. Le SYSTÈME (barrière §4) pousse les
  commits du pod (mode `git_native`, gate I-CBC déléguée à `Deliverable.publish`) sur la
  feature-branch, PUIS **ouvre la PR** `feature → base`. La PR devient la surface review+promote :
  domicile des verdicts (reviews natives) + entonnoir unique vers `main`. `body` porte `Closes #N`
  → la forge auto-close l'issue au merge (lien ticket↔PR maintenu nativement).

  Remplace le push `lcars/issue-N-role` + comment `[hop:role:sha]` de la séquence §5 maison.
  **Idempotent** : `open_pr` retrouve une PR déjà ouverte pour la même head (replay-safe).

  `hop` : `:repo`, `:issue_number`, `:role`, `:deliverable_opts` (dont `:target_branch` = la head),
  `:base_branch` (défaut `"main"`), `:title`/`:pr_body` (optionnels). `opts` : seams `:deliverable`
  / `:forge_client` / `:forge_opts`.

  Returns `{:ok, %{commit_sha, pr_number}}` | `{:error, {step, reason}}`.
  """
  @spec open_deliverable_pr(map(), keyword()) ::
          {:ok, %{commit_sha: String.t(), pr_number: integer()}} | {:error, {atom(), term()}}
  def open_deliverable_pr(hop, opts \\ []) when is_map(hop) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Pipeline.Deliverable)
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    repo = Map.fetch!(hop, :repo)
    n = Map.fetch!(hop, :issue_number)
    role = Map.get(hop, :role, "engineer")
    base = Map.get(hop, :base_branch, "main")
    head = Map.fetch!(Map.fetch!(hop, :deliverable_opts), :target_branch)
    title = Map.get(hop, :title, "Livrable ##{n} — brique livrée par #{role} (engineer)")
    body = Map.get(hop, :pr_body, default_pr_body(n, role))

    # ②.1e — la PR est ouverte AU NOM DE L'ENG (token de rôle, `as_role`), pas du compte système :
    # l'auteur de la PR sur la forge = Engineer (l'eng a fait le boulot). Token absent → fallback
    # système loggué (RoleToken, honnête-dégradé). Barrière §4 : c'est le SYSTÈME qui poste avec le
    # token de rôle, jamais le pod (forge-aveugle).
    with {:ok, sha} <- step1_publish(hop, deliverable),
         {:ok, pr} <-
           open_pr_step(forge, repo, head, base, title, body, as_role(forge_opts, role)) do
      Logger.info("HopCompleter: ##{n} #{role} → PR ##{pr} (head=#{head}, sha=#{sha})")
      {:ok, %{commit_sha: sha, pr_number: pr}}
    end
  end

  # Corps de PR par défaut — descriptif (traça honnête : QUI a fait QUOI) + `Closes #N` (auto-close
  # natif au merge → close APRÈS merge, jamais avant). [[feedback_verbose_descriptive_traceable]]
  defp default_pr_body(n, role) do
    "Livrable de la brique ##{n}, produit par **#{role}** (engineer). Le système a poussé le commit " <>
      "(l'eng code dans son workspace, le système publie — barrière forge-aveugle, le pod n'a pas de " <>
      "token forge). Reviews demandées aux juges (qualifier + reviewer) ; merge à l'approbation.\n\n" <>
      "Closes ##{n}"
  end

  defp open_pr_step(forge, repo, head, base, title, body, forge_opts) do
    case forge.open_pr(repo, head, base, title, Keyword.put(forge_opts, :body, body)) do
      {:ok, pr} -> {:ok, pr}
      {:error, reason} -> {:error, {:open_pr, reason}}
    end
  end

  @doc """
  **PR-natif (Corr.3)** — verdict de juge → **review native** sur la PR. Remplace le comment
  `[hop:role:sha]` maison : le verdict de gate vit comme review Gitea (APPROVED / REQUEST_CHANGES),
  traçable, lisible sans query custom. C'est le DOMICILE durable du verdict.

  `hop` : `:repo`, `:pr_number`, `:role`, `:review_event` (`:approve` | `:request_changes` |
  `:comment`), `:review_body` (optionnel, défaut généré du rôle + verdict).
  Returns `{:ok, :reviewed}` | `{:error, {:review, reason}}`.
  """
  @spec record_review(map(), keyword()) :: {:ok, :reviewed} | {:error, {:review, term()}}
  def record_review(hop, opts \\ []) when is_map(hop) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(hop, :repo)
    pr = Map.fetch!(hop, :pr_number)
    event = Map.fetch!(hop, :review_event)
    body = Map.get(hop, :review_body, default_review_body(hop, event))

    # ②.1e — la review native est postée AU NOM DU JUGE (token de rôle, `as_role`) : sur la forge,
    # l'auteur de la review = qualifier/reviewer (avatar/traça honnête), pas le compte système. Token
    # absent → fallback système loggué (RoleToken, honnête-dégradé). Barrière §4 préservée (le pod
    # n'a pas de token ; c'est le SYSTÈME qui poste la review en son nom).
    # NB `ForgeClient.post_review/5` rend `:ok` (pas `{:ok, _}`) sur succes — matcher les deux
    # (un seam test peut rendre l'un ou l'autre ; le contrat reel = `:ok`).
    case forge.post_review(repo, pr, event, body, as_role(forge_opts, Map.get(hop, :role))) do
      :ok -> {:ok, :reviewed}
      {:ok, _} -> {:ok, :reviewed}
      {:error, reason} -> {:error, {:review, reason}}
    end
  end

  # Corps de review par défaut — descriptif (rôle juge + verdict + ce qui est jugé).
  # [[feedback_verbose_descriptive_traceable]]
  defp default_review_body(hop, event) do
    role = Map.get(hop, :role, "juge")

    case event do
      :approve ->
        "Verdict du juge **#{role}** : **APPROUVÉ** — la brique satisfait son critère de revue."

      :request_changes ->
        "Verdict du juge **#{role}** : **CHANGEMENTS DEMANDÉS** — la brique ne satisfait pas " <>
          "son critère ; le producteur (engineer) doit corriger et re-pousser sur la même PR."

      _ ->
        "Commentaire du juge **#{role}** : verdict non concluant (en attente)."
    end
  end

  @doc """
  **PR-natif (Corr.3)** — PROMOTE : merge la PR en **fast-forward-only**. C'est le terminal `:pass`
  du dernier stage — auto-close de l'issue via `Closes #N`. Sous bail serial + funnel append-only,
  la feature est descendante linéaire de `main` → FF garanti. Échec FF = invariant serial violé
  (deux branches sur le même code) → fail-loud `{:merge, _}`, PAS un conflit à résoudre.

  `hop` : `:repo`, `:pr_number`. Returns `{:ok, :promoted}` | `{:error, {:merge, reason}}`.
  """
  @spec promote(map(), keyword()) :: {:ok, :promoted} | {:error, {:merge, term()}}
  def promote(hop, opts \\ []) when is_map(hop) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(hop, :repo)
    pr = Map.fetch!(hop, :pr_number)
    issue_n = Map.fetch!(hop, :issue_number)
    producer = producer_of(Map.get(hop, :producer_branch))

    # Sceau UNIQUE (F-arch-MCP) : commentaire gatekeeper + merge signé gatekeeper — EXACTEMENT le même
    # chemin que `StageDispatcher.promote_pr`. Avant, ce terminal `:promote` (ex. après escalade §L441)
    # mergeait avec `forge_opts` brut = token système, sans commentaire (merge attribué `lcars-system`).
    gk_opts = as_role(forge_opts, Fleet.Pilot.GatekeeperSeal.gatekeeper_role())

    case Fleet.Pilot.GatekeeperSeal.seal_and_merge(forge, repo, pr, issue_n, producer, gk_opts) do
      :ok -> {:ok, :promoted}
      {:error, {:merge, _}} = err -> err
      {:error, {:seal_comment, reason}} -> {:error, {:merge, {:seal_comment, reason}}}
    end
  end

  # Producteur extrait du `producer_branch` (`lcars/issue-N-<producteur>`) pour le commentaire de sceau.
  defp producer_of(branch) when is_binary(branch) do
    case Regex.run(~r{issue-\d+-(.+)$}, branch) do
      [_, producer] -> producer
      _ -> "engineer"
    end
  end

  defp producer_of(_), do: "engineer"

  @doc """
  **PR-natif (Corr.3) — orchestrateur de fin-de-hop.** Compose les primitives PR
  (`open_deliverable_pr`/`record_review`/`promote`) + le routage selon l'`intent` de gate.
  Remplace la sequence §5 `complete/2` (push `lcars/issue-N-role` + comment `[hop:role:sha]` +
  state + assignee/close + unlock) sur le happy-path : la PR devient le domicile review+promote,
  la forge auto-close l'issue au merge (`Closes #N`).

  Le hop est **deja resolu** par l'appelant (`HopConsumer` connait la carte + le `deliverable_mode`) :

    * `:pr_role` — `:producer` (role git_native → pousse le code, ouvre la PR) | `:judge`
      (role payload → review la PR du producteur).
    * `:intent` — decision de gate : `:advance` (stage suivant) | `:promote` (terminal) |
      `:rework` (rebond).
    * `:producer_branch` — head de la PR a reviewer (`lcars/issue-N-<producteur>`) ; requis pour
      un juge (lookup de la PR). Producteur : sa propre `deliverable_opts.target_branch` sert de head.
    * `:next_assignee` — role suivant (`:advance`) ou role de rebond (`:rework`) ; `nil` en terminal.

  ## Routage (4-C, switch review-request)

  Le trigger du stage suivant = la review-request native (`request_review`), plus `set_assignee` :
  le producteur reste assigne (Entry), les juges sont dispatches via la PR (`dispatch_review`). La
  position carte (`post_route`) reste gravee sur l'issue. Le verrou `lcars-in-flight` est leve en
  DERNIER sur le bon numero : producteur -> l'ISSUE (verrou pose par `dispatch_issue`) ; juge -> la
  PR (verrou pose par `dispatch_review`).

  Returns `{:ok, :promoted | :review_requested | :rework_requested}` | `{:error, {step, reason}}`.
  """
  @spec complete_pr(map(), keyword()) ::
          {:ok, :promoted | :review_requested | :rework_requested | :reviewed}
          | {:error, {atom(), term()}}
  def complete_pr(hop, opts \\ []) when is_map(hop) do
    case Map.fetch!(hop, :pr_role) do
      :producer -> complete_producer(hop, opts)
      :judge -> complete_judge(hop, opts)
    end
  end

  # Producteur (engineer, git_native) : pousse le livrable + ouvre la PR, PUIS route. Sur un rework
  # de son PROPRE gate (code rejete), pas de PR — re-dispatch direct (le producteur recommence).
  defp complete_producer(%{intent: :rework} = hop, opts), do: route(hop, nil, opts)

  defp complete_producer(hop, opts) do
    with {:ok, %{pr_number: pr}} <- open_deliverable_pr(hop, opts) do
      _ = maybe_post_eng_summary(hop, pr, opts)
      route(hop, pr, opts)
    end
  end

  # VOIX DE L'ENG sur la PR (info SORTANTE, [[feedback_verbose_descriptive_traceable]]) : poste le
  # `summary` du producteur (ce qu'il a fait à la livraison / sa réponse à la review au rework) en
  # commentaire PR, AU NOM DE L'ENG (`as_role` — traça honnête ②.1e ; le pod reste forge-aveugle, c'est
  # le SYSTÈME qui poste). Best-effort : un échec de post ne casse PAS la complétion (le livrable = le
  # commit, déjà poussé). Absent/vide → rien (pas de commentaire vide). Couvre livraison ET rework (les
  # deux passent ici via open_deliverable_pr — PR neuve ou existante).
  defp maybe_post_eng_summary(hop, pr, opts) do
    case Map.get(hop, :eng_summary) do
      summary when is_binary(summary) and summary != "" ->
        forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
        forge_opts = Keyword.get(opts, :forge_opts, [])
        repo = Map.fetch!(hop, :repo)
        n = Map.fetch!(hop, :issue_number)
        role = Map.get(hop, :role, "engineer")
        role_opts = as_role(forge_opts, role)

        # #6 (2026-06-18) : la voix de l'eng sur DEUX canaux à 2 buts distincts — la PR (revue du
        # diff, contexte code) ET le TICKET (réponse au mandat, « voici ce que j'ai fait », contexte
        # issue). Avant, seul la PR était servie (trou). Best-effort, `as_role` (le pod reste forge-aveugle,
        # le SYSTÈME poste en son nom — même geste que le commentaire gatekeeper sur le ticket).
        _ =
          forge.post_comment(
            repo,
            pr,
            "## 🔧 Note de l'#{role} (livrable)\n\n#{summary}",
            role_opts
          )

        _ =
          forge.post_comment(
            repo,
            n,
            "## 🔧 Note de l'#{role} sur le ticket\n\n#{summary}",
            role_opts
          )

        :ok

      _ ->
        :noop
    end
  end

  # Juge (payload) : retrouve la PR du producteur, enregistre la review native (verdict→event),
  # PUIS route. La review native EST le domicile durable du verdict (vs le comment maison §5).
  defp complete_judge(hop, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(hop, :repo)
    base = Map.get(hop, :base_branch, "main")
    head = Map.get(hop, :producer_branch)

    case resolve_pr(forge, repo, head, base, forge_opts) do
      {:ok, pr} ->
        # Juge de LIVRABLE (la PR existe) : verdict tracé en review native + route PR (request next / merge).
        with {:ok, :reviewed} <- record_review(review_hop(hop, pr), opts) do
          route(hop, pr, opts)
        end

      {:error, {:pr_lookup, :no_producer_branch}} = err ->
        # #8.E — juge de MANDAT (judge_target:mandate) : PRÉ-PR, donc pas de PR ni de review native → le
        # verdict se trace en COMMENTAIRE issue et l'avance est ISSUE-LEVEL (grave la route → le poller
        # dispatche le stage suivant). Réutilise `complete` (la MÊME complétion issue-level que
        # close_with_trace : publish sauté via deliverable_opts nil + hop_sha). Tout AUTRE juge sans PR =
        # erreur (un livrable était attendu) → fail-loud INCHANGÉ (jamais un merge sur PR introuvable).
        if Map.get(hop, :judge_target) == "mandate" do
          hop |> Map.merge(%{deliverable_opts: nil, hop_sha: "mandate-verdict"}) |> complete(opts)
        else
          err
        end

      {:error, _} = err ->
        err
    end
  end

  defp resolve_pr(_forge, _repo, head, _base, _opts) when not is_binary(head),
    do: {:error, {:pr_lookup, :no_producer_branch}}

  defp resolve_pr(forge, repo, head, base, forge_opts) do
    case forge.get_pr_for_branch(repo, head, base, forge_opts) do
      {:ok, pr} -> {:ok, pr}
      {:error, reason} -> {:error, {:pr_lookup, reason}}
    end
  end

  defp review_hop(hop, pr) do
    # ②.1d : un juge no-carte porte `:review_event` (mappé du gate-decision continue/abandon par
    # HopConsumer). À défaut (legacy carte), on dérive de l'intent. Le `:review_event` explicite prime.
    event = Map.get(hop, :review_event) || review_event_for_intent(Map.fetch!(hop, :intent))

    hop
    |> Map.put(:pr_number, pr)
    |> Map.put(:review_event, event)
  end

  # Verdict de gate → event de review native. `:rework` (gate fail) = REQUEST_CHANGES ; `:advance`/
  # `:promote` (gate pass) = APPROVED. Le `:review_body` (optionnel) prime sur le corps genere.
  defp review_event_for_intent(:rework), do: :request_changes
  defp review_event_for_intent(_), do: :approve

  # Routage commun selon l'intent (Corr.3 4-C). Le trigger du stage suivant = la review-request
  # native (`request_review`), plus `set_assignee` : le producteur reste assigne (Entry), les juges
  # sont dispatches via la PR (`dispatch_review`). `post_route` (position carte) RESTE sur l'issue.
  # `lcars-in-flight` leve en DERNIER sur le bon numero : producteur -> l'ISSUE (verrou pose par
  # dispatch_issue) ; juge -> la PR (verrou pose par dispatch_review). `pr` = nil seulement sur un
  # rework producteur (pas de PR).
  #   :promote -> merge FF (la PR `Closes #N` ferme l'issue), unlock ;
  #   :advance -> request_review(next) + post_route, unlock ;
  #   :rework  -> post_route(rebond), unlock. Re-dispatch : producteur via l'assignee Entry conserve
  #               (pas de PR encore) ; juge -> re-spawn producteur sur changes-requested (4-C-iv).
  defp route(%{intent: :promote} = hop, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    # F-arch-MCP : transmet issue_number + producer_branch à `promote` (le sceau gatekeeper en a besoin
    # pour le commentaire de fin). Avant, le hop était réduit à {repo, pr_number} → merge sans trace.
    promote_hop = %{
      repo: hop.repo,
      pr_number: pr,
      issue_number: hop.issue_number,
      producer_branch: Map.get(hop, :producer_branch)
    }

    with {:ok, :promoted} <- promote(promote_hop, opts),
         {:ok, _} <- unlock(forge, hop.repo, lock_number(hop, pr), forge_opts) do
      {:ok, :promoted}
    end
  end

  defp route(%{intent: :advance} = hop, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = hop.repo
    next = Map.fetch!(hop, :next_assignee)

    with :ok <- request_review_step(forge, repo, pr, next, forge_opts),
         {:ok, _} <- bridge_route(forge, repo, hop.issue_number, hop, forge_opts),
         {:ok, _} <- unlock(forge, repo, lock_number(hop, pr), forge_opts) do
      {:ok, :review_requested}
    end
  end

  defp route(%{intent: :rework} = hop, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = hop.repo

    with {:ok, _} <- bridge_route(forge, repo, hop.issue_number, hop, forge_opts),
         {:ok, _} <- unlock(forge, repo, lock_number(hop, pr), forge_opts) do
      {:ok, :rework_requested}
    end
  end

  # ②.1d — producteur SANS carte (single-brique) : la PR est ouverte (`complete_producer`) → on met
  # les JUGES (`:reviewer_roles`, défaut qualifier+reviewer) en `requested_reviewers` (le poller
  # `dispatch_review` les spawn un à un), on ASSIGNE l'HUMAIN à la PR (②.1e — voir quel humain a
  # drivé), puis on lève le verrou de l'ISSUE (la PR ouverte fait skip l'issue côté poller via
  # `pulls_issue_ids`). PAS de merge ici : le merge est piloté par l'état-PR (dispatch_review, quand
  # tous les juges ont approuvé). Branch-protection OFF en dev (décision user) → LCARS agrège, interim.
  defp route(%{intent: :review} = hop, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = hop.repo

    # Unlock DES DEUX numéros (idempotent : remove_label no-op si absent). 1re livraison → le verrou est
    # sur l'ISSUE (posé par `dispatch_issue`) ; RE-livraison de rework → le verrou est sur la PR (posé
    # par `dispatch_review` :rework). On lève les deux pour ne stuck ni l'un ni l'autre.
    with :ok <- request_reviews_step(forge, repo, pr, reviewer_roles(opts), forge_opts),
         {:ok, _} <- assign_human_step(forge, repo, pr, forge_opts),
         {:ok, _} <- unlock(forge, repo, hop.issue_number, forge_opts),
         {:ok, _} <- unlock(forge, repo, pr, forge_opts) do
      {:ok, :review_requested}
    end
  end

  # ②.1d — juge SANS carte : la review native a déjà été postée par `complete_judge` (`record_review`,
  # signée par le token du juge). Il ne reste qu'à lever le verrou de la PR. Le merge/rework est décidé
  # par le poller (`dispatch_review`, REVIEWS-DRIVEN : il lit la liste des reviews — verdict décisif par
  # juge — pas `requested_reviewers` que Gitea ne vide pas, live #6). Pas d'action sur `requested_reviewers`
  # (la DELETE est un no-op sur un juge ayant déjà reviewé, vérifié live).
  defp route(%{intent: :reviewed} = hop, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    with {:ok, _} <- unlock(forge, hop.repo, lock_number(hop, pr), forge_opts) do
      {:ok, :reviewed}
    end
  end

  # Demande la review de TOUS les juges d'un coup (DN §1.4 : qualifier+reviewer en requested_reviewers).
  # Liste vide = trou de config (jamais merger sans juge en interim) → fail-loud.
  defp request_reviews_step(_forge, _repo, _pr, [], _forge_opts),
    do: {:error, {:request_review, :no_reviewers}}

  defp request_reviews_step(forge, repo, pr, reviewers, forge_opts) do
    case forge.request_review(repo, pr, reviewers, forge_opts) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:request_review, reason}}
    end
  end

  # ②.1e — assigne l'HUMAIN commanditaire à la PR (comme le ticket : voir QUEL humain a drivé les
  # agents). L'humain DRIVE, ne fait rien → il ne signe rien, mais il est l'assignee partout (traça du
  # driver). Assignee = champ de routing (pas d'authorship) → token système OK. Humain irrésoluble →
  # best-effort (le code EST livré) : log + on n'échoue pas le hop.
  defp assign_human_step(forge, repo, pr, forge_opts) do
    case Fleet.Credentials.Human.current() do
      {:ok, login} ->
        case forge.set_assignee(repo, pr, login, forge_opts) do
          {:ok, _} = ok -> ok
          {:error, reason} -> {:error, {:assign_human, reason}}
        end

      {:error, reason} ->
        Logger.warning(
          "HopCompleter: humain commanditaire irrésoluble (#{inspect(reason)}) — PR ##{pr} non assignée"
        )

        {:ok, :no_human}
    end
  end

  # Juges du modèle single-brique (DN §1.4) : config `:reviewer_roles` (data catalogue, défaut
  # qualifier+reviewer), surchargée par `opts` pour les tests. Symétrique de `:producer_role`.
  defp reviewer_roles(opts) do
    Keyword.get(opts, :reviewer_roles) ||
      Application.get_env(:fleet_pilot, :reviewer_roles, ["qualifier", "reviewer"])
  end

  # ②.1e — injecte le token du compte de RÔLE dans les forge_opts → le SYSTÈME poste EN SON NOM
  # (avatar/traça honnête, même mécanique que `create_ticket`/arch). `nil` (token absent/illisible/vide)
  # → forge_opts inchangé → fallback token système ; `RoleToken.token/1` émet un `Logger.warning` sur
  # ce dégradé (token absent/illisible/vide), il est donc OBSERVABLE ici. Barrière §4 préservée :
  # c'est le système qui poste avec le token de rôle, jamais le pod (forge-aveugle).
  defp as_role(forge_opts, role) when is_binary(role) and role != "" do
    case Fleet.Credentials.RoleToken.token(role) do
      t when is_binary(t) -> Keyword.put(forge_opts, :token, t)
      _ -> forge_opts
    end
  end

  defp as_role(forge_opts, _role), do: forge_opts

  # Verrou a lever : producteur -> l'issue (verrou pose par dispatch_issue) ; juge -> la PR (verrou
  # pose par dispatch_review). Un rework producteur (pr nil) tombe sur l'issue.
  defp lock_number(%{pr_role: :judge}, pr) when is_integer(pr), do: pr
  defp lock_number(%{issue_number: n}, _pr), do: n

  # Grave la POSITION carte [lcars-route:p:s] sur l'issue (lue par StageDispatcher/dispatch_review
  # pour identifier le stage du juge : l'assignee/le reviewer seul ne l'identifie pas, un role peut
  # etre sur N stages). Reste (autorite de navigation) ; seul le TRIGGER (set_assignee) est remplace
  # par la review-request. Grave si pipeline+next_stage presents (sinon 1-stage/terminal, pas de route).
  defp bridge_route(forge, repo, n, hop, forge_opts) do
    case {Map.get(hop, :pipeline), Map.get(hop, :next_stage)} do
      {p, s} when is_binary(p) and is_binary(s) ->
        case forge.post_route(repo, n, p, s, forge_opts) do
          {:ok, _} = ok -> ok
          {:error, reason} -> {:error, {:route, reason}}
        end

      _ ->
        {:ok, :no_route}
    end
  end

  defp request_review_step(forge, repo, pr, reviewer, forge_opts) do
    case forge.request_review(repo, pr, [reviewer], forge_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_review, reason}}
    end
  end

  defp unlock(forge, repo, n, forge_opts) do
    case forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:unlock, reason}}
    end
  end

  # ── Étape 1 : commit + push livrable (ou hop_sha fourni si pas de git) ──────
  defp step1_publish(hop, deliverable) do
    case Map.get(hop, :deliverable_opts) do
      nil ->
        case Map.get(hop, :hop_sha) do
          sha when is_binary(sha) and sha != "" -> {:ok, sha}
          _ -> {:error, {:publish, :no_deliverable_no_hop_sha}}
        end

      d_opts when is_map(d_opts) ->
        case deliverable.publish(d_opts) do
          {:ok, %{commit_sha: sha}} -> {:ok, Map.get(hop, :hop_sha, sha)}
          {:error, reason} -> {:error, {:publish, reason}}
        end
    end
  end

  # ── Étape 2 : comment signé [hop:role:sha], dédup ──────────────────────────
  # F064 : la signature ET le bloc result viennent de ForgeClient (co-localisés avec leurs
  # parseurs `@hop_marker_rx` / `parse_result_block`). On NE passe PAS par le seam `forge`
  # (un stub ne doit pas pouvoir désynchroniser le format du parseur réel).
  #
  # NB `:outputs` : embarque le `result_K` du stage qui finit → lisible sans query séparée
  # (recovery, contexte). En B (§L441) HopConsumer ne pose plus `:outputs` (l'ex-cas A2.3b
  # "avance vers un gatekeeper-stage" n'existe plus) → seam générique, inactif côté HopConsumer
  # mais conservé (autres appelants / extensibilité).
  defp step2_comment(forge, repo, n, role, sha, hop, forge_opts) do
    signature = ForgeClient.hop_marker(role, sha)

    body =
      Map.get(hop, :comment_body, default_comment(role, sha)) <>
        ForgeClient.result_block(Map.get(hop, :outputs)) <> "\n\n" <> signature

    case forge.post_comment(repo, n, body, Keyword.put(forge_opts, :dedup_signature, signature)) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:comment, reason}}
    end
  end

  # ── Étape 4 : assignee suivant (A2) OU close (1-stage terminal) ────────────
  # (Étape 3 « PATCH state:* » retirée — #5.2 D4. N° de step conservés = mapping DN §5.)
  # Reassign : grave la ROUTE du stage suivant AVANT le PATCH assignee (A2.1) — le poller
  # ne doit voir le nouvel assignee qu'avec sa position carte déjà posée (sinon le spawn
  # suivant ne saurait pas quel stage il est). post_route idempotent (dédup marqueur).
  defp step4_route(forge, repo, n, hop, forge_opts) do
    case Map.get(hop, :next_assignee) do
      nil ->
        case forge.close_issue(repo, n, forge_opts) do
          {:ok, _} -> {:ok, :completed}
          {:error, reason} -> {:error, {:close, reason}}
        end

      next when is_binary(next) ->
        # #8.A : AVANCE = grave la route du stage suivant. PLUS de `set_assignee(next)` — l'assignee
        # reste l'HUMAIN (traça) ; le rôle du next stage (`next`) est dérivé de la route au dispatch
        # (`StageDispatcher.carte_role`), pas de l'assignee. `next` (next_role présent) distingue
        # AVANCE vs terminal (nil → close).
        case maybe_post_route(forge, repo, n, hop, forge_opts) do
          {:ok, _} ->
            Logger.debug(
              "HopCompleter advance #{repo}##{n} → next stage role=#{next} (route gravée, assignee=humain inchangé)"
            )

            {:ok, :reassigned}

          {:error, reason} ->
            {:error, {:reassign, reason}}
        end
    end
  end

  defp maybe_post_route(forge, repo, n, hop, forge_opts) do
    case {Map.get(hop, :pipeline), Map.get(hop, :next_stage)} do
      {p, s} when is_binary(p) and is_binary(s) -> forge.post_route(repo, n, p, s, forge_opts)
      _ -> {:ok, :no_route}
    end
  end

  # ── Étape 5 : retire le verrou (DERNIER) ───────────────────────────────────
  defp step5_unlock(forge, repo, n, forge_opts) do
    case forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:unlock, reason}}
    end
  end

  defp default_comment(role, sha) do
    "Livrable de **#{role}** poussé par le système (fin-de-hop). Source: `#{sha}`."
  end
end
