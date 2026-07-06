defmodule Fleet.Pilot.StepRunCompleter do
  @moduledoc """
  Primitive de **fin-de-step-run** (la forge EST la machine à états ; ce module en
  applique les transitions). Quand un pod (step courant) a terminé, le
  **SYSTÈME** — pas le pod, qui n'a ni token ni outil forge (forge-aveugle) —
  applique la transition vers le step suivant. C'est la pièce qui REMPLACE le
  chaînage inter-step de l'Executor (RAM) par une séquence forge-driven idempotente.

  ## Séquence ordonnée idempotente

  L'atomicité est impossible (Gitea n'a pas de transaction ; un step_run = ~5
  écritures HTTP). On la remplace par un ORDRE où le trigger du poller (PATCH
  assignee) est l'**avant-dernier** et le verrou est levé en **dernier** :

    1. **Commit + push livrable** — délégué à `Deliverable.publish` (gate de
       cohérence workspace + push borné). Indissociables : le commit local seul
       n'est pas vu par la forge. Retourne le `commit_sha` qui signe le step_run.
    2. **Comment signé** `[step_run:<role>:<sha>]` — dédup par signature (replay-safe).
       *(Pas d'étape 3 « PATCH `state:*` » : l'état vit dans la route-comment,
       pas dans un label `state:*`. Les n° de step suivants gardent leur mapping.)*
    4. **Routage du step suivant** :
         * `next_assignee` présent (multi-step) → `set_assignee(next)` ; le
           poller ne verra le suivant que quand 1-3 sont OK. **(le calcul de
           `next_assignee` depuis la workflow_map est en amont, pas ici.)**
         * `next_assignee == nil` (1-step / terminal) → `close_issue`.
    5. **Retire `lcars-in-flight`** — en DERNIER : le poller ne re-spawn le
       suivant que quand TOUT est fini.

  **Garantie crash** : un crash à n'importe quelle étape laisse le verrou posé
  (sauf après 5) → le poller ne re-spawn pas ; la recovery rejoue la séquence,
  les étapes faites skippent (write-ops idempotentes + dédup comment + push
  idempotent). Pas de double-livrable ni double-comment.

  ## Seams

  `:deliverable` (défaut `Fleet.Workflow.Deliverable`), `:forge_client` (défaut
  `Fleet.Pilot.ForgeClient`) — stubés en test. `:deliverable_opts` quand le step_run
  produit un livrable git ; absent/`nil` = pas de livrable git (ex. verdict de
  juge en mode payload — le `step_run_sha` est alors fourni explicitement).

  ## Sous-modules

    * `Texts` — wording PAR DÉFAUT (pr_body/review_body/comment signé), générateurs purs ;
      les overrides de l'appelant priment.
    * `Emissions` — émissions ANNEXES best-effort de la livraison producteur (voix eng,
      slot-freeze `deliverable.published`) ; hors séquence par contrat.

  Le routage par intent (`route/3` ×5) reste ICI : il rappelle les primitives publiques
  (`promote`) et partage `unlock`/`post_route_if_present` (autorités uniques) avec la
  séquence maison — l'extraire créerait un seam bidirectionnel (mauvaise frontière).
  """

  require Logger

  alias Fleet.Pilot.ForgeClient
  alias Fleet.Pilot.ForgeProtocol
  alias Fleet.Pilot.Labels
  alias Fleet.Pilot.Roles

  # Émissions ANNEXES de la livraison producteur (voix eng + slot-freeze) — best-effort par
  # contrat (un échec ne casse jamais la complétion), d'où leur extraction hors séquence.
  alias Fleet.Pilot.StepRunCompleter.Emissions

  # Autorité du WORDING par défaut (pr_body/review_body/comment signé) — générateurs purs ;
  # les overrides de l'appelant (`:pr_body`/`:review_body`/`:comment_body`) priment toujours.
  alias Fleet.Pilot.StepRunCompleter.Texts

  # Vocabulaire protocole = source unique Fleet.Pilot.Labels.
  @in_flight_label Labels.in_flight()

  @typedoc """
  Décrit la fin-de-step-run d'un rôle sur une issue.

    * `:repo` / `:issue_number` — cible forge (obligatoires)
    * `:role` — le rôle qui vient de finir (signe le comment)
    * `:deliverable_opts` — opts passés tel quel à `Deliverable.publish/1`
      (mode/workspace/base_sha/remote/target_branch/...). `nil` = pas de
      livrable git ; alors `:step_run_sha` requis.
    * `:step_run_sha` — override de la signature de step_run (défaut = commit_sha publié)
    * `:next_assignee` — login du rôle suivant (workflow_map) ; `nil` = terminal → close
    * `:comment_body` — corps lisible du comment (la signature machine est
      toujours ajoutée) ; défaut généré
  """
  @type step_run :: %{
          required(:repo) => String.t(),
          required(:issue_number) => integer(),
          required(:role) => String.t(),
          optional(:deliverable_opts) => map() | nil,
          optional(:step_run_sha) => String.t(),
          optional(:next_assignee) => String.t() | nil,
          optional(:comment_body) => String.t()
        }

  @doc """
  Applique la séquence ordonnée de fin-de-step-run. Idempotente sur replay.

  `opts` : seams `:deliverable` / `:forge_client` / `:forge_opts`.

  Retourne `{:ok, :completed}` (terminal → issue fermée) | `{:ok, :reassigned}`
  (multi-step → assignee suivant posé) | `{:error, {step, reason}}`.
  """
  @spec complete(step_run(), keyword()) ::
          {:ok, :completed | :reassigned} | {:error, {atom(), term()}}
  def complete(step_run, opts \\ []) when is_map(step_run) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Workflow.Deliverable)
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.fetch!(step_run, :role)

    with {:ok, sha} <- step1_publish(step_run, deliverable),
         {:ok, _} <- step2_comment(forge, repo, n, role, sha, step_run, forge_opts),
         # Gap AVANT la route : le comment de verdict prend un `created_at` strictement antérieur à
         # la route (sinon même seconde → ordre dashboard arbitraire, « logiquement avant, affiché après »).
         :ok <- space_writes(opts),
         {:ok, routed} <- step4_route(forge, repo, n, step_run, forge_opts),
         {:ok, _} <- unlock(forge, repo, n, forge_opts) do
      Logger.info("StepRunCompleter: #{repo}##{n} role=#{role} sha=#{sha} → #{routed}")

      {:ok, routed}
    end
  end

  @awaits_arch_label Labels.awaits_arch()

  @doc """
  Fin-de-step_run ALTERNATIVE : un verdict gatekeeper **humain**
  (`escalate_user`/`halt_wait_input`/`redirect`/absent/invalide).
  Le SYSTÈME pose `lcars-awaits-arch` + retire le verrou ; NE close PAS, NE reassign PAS.
  L'issue attend une action humaine **via l'arch** (le sas unique vers l'humain) ;
  le poller la **SKIP** (`StepDispatcher.decide` → `:awaits_arch`).

  Pas de livrable git ici (le verdict vit dans le comment signé ; `verdict.json` =
  item `submit_result` séparé). Ordre : comment → `lcars-awaits-arch` → unlock (DERNIER,
  même principe que la séquence nominale : un crash laisse le verrou → poller skip →
  recovery rejoue, idempotent via dédup comment + add/remove label idempotents).

  `step_run` : `:repo`, `:issue_number`, `:role`, `:decision`. Returns `{:ok, :awaiting_arch}`
  | `{:error, {:await_arch, reason}}`.
  """
  @spec await_arch(map(), keyword()) :: {:ok, :awaiting_arch} | {:error, {:await_arch, term()}}
  def await_arch(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.fetch!(step_run, :role)
    decision = Map.get(step_run, :decision)

    signature = "[step_run:#{role}:await:#{decision}]"

    # `:comment_body` (optionnel) = trace fournie par l'appelant (ex. StepRunConsumer porte le
    # verdict gatekeeper attribué + halt_invalid distingué). Absent → corps par défaut.
    lead =
      Map.get(step_run, :comment_body) ||
        "Verdict du juge **#{role}** : `#{inspect(decision)}`."

    # ADRESSÉ à l'arch (le sas unique vers l'humain ; l'humain n'a pas d'autre canal vers la fleet).
    # L'arch reprend le brief (corrige + re-soumet) ou tranche avec son humain. PAS de re-assign (assignee
    # = humain owner) : l'arch query son inbox `lcars-awaits-arch` ; l'issue reste hors-dispatch.
    body =
      "**Architecte** (auteur du brief) — " <>
        lead <>
        "\n\nReprends ce brief : corrige-le puis re-soumets (relance le cycle), ou tranche avec ton humain " <>
        "(il n'a pas d'autre canal vers la fleet que toi). L'issue reste hors-dispatch tant que " <>
        "`lcars-awaits-arch` est posé.\n\n" <> signature

    # Le commentaire de VERDICT est AU NOM DU JUGE (`as_role` : le texte dit « Verdict du juge X »,
    # l'auteur forge doit être X, pas le compte système — sinon traça menteuse, masque le worker). Les
    # labels (add/remove) restent SYSTÈME : l'état protocole appartient au système, pas au juge.
    with {:ok, _} <-
           forge.post_comment(
             repo,
             n,
             body,
             forge_opts |> ForgeClient.as_role(role) |> Keyword.put(:dedup_signature, signature)
           ),
         # Gap AVANT les labels : le comment de verdict prend un `created_at` antérieur (lecture cohérente).
         :ok <- space_writes(opts),
         {:ok, _} <- forge.add_label(repo, n, @awaits_arch_label, forge_opts),
         {:ok, _} <- forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      Logger.info(
        "StepRunCompleter: #{repo}##{n} role=#{role} → awaiting_arch (decision=#{inspect(decision)})"
      )

      {:ok, :awaiting_arch}
    else
      {:error, reason} -> {:error, {:await_arch, reason}}
    end
  end

  @doc """
  **PR-natif** — livraison engineer → PR. Le SYSTÈME (le pod est forge-aveugle) pousse les
  commits du pod (mode `git_native`, gate de cohérence déléguée à `Deliverable.publish`) sur la
  feature-branch, PUIS **ouvre la PR** `feature → base`. La PR devient la surface review+promote :
  domicile des verdicts (reviews natives) + entonnoir unique vers `main`. `body` porte `Closes #N`
  → la forge auto-close l'issue au merge (lien issue↔PR maintenu nativement).

  Remplace le push `lcars/issue-N-role` + comment `[step_run:role:sha]` de la séquence maison.
  **Idempotent** : `open_pr` retrouve une PR déjà ouverte pour la même head (replay-safe).

  `step_run` : `:repo`, `:issue_number`, `:role`, `:deliverable_opts` (dont `:target_branch` = la head),
  `:base_branch` (défaut `"main"`), `:title`/`:pr_body` (optionnels). `opts` : seams `:deliverable`
  / `:forge_client` / `:forge_opts`.

  Returns `{:ok, %{commit_sha, pr_number}}` | `{:error, {step, reason}}`.
  """
  @spec open_deliverable_pr(map(), keyword()) ::
          {:ok, %{commit_sha: String.t(), pr_number: integer()}} | {:error, {atom(), term()}}
  def open_deliverable_pr(step_run, opts \\ []) when is_map(step_run) do
    deliverable = Keyword.get(opts, :deliverable, Fleet.Workflow.Deliverable)
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    repo = Map.fetch!(step_run, :repo)
    n = Map.fetch!(step_run, :issue_number)
    role = Map.get(step_run, :role, "engineer")
    base = Map.get(step_run, :base_branch, "main")
    head = Map.fetch!(Map.fetch!(step_run, :deliverable_opts), :target_branch)
    title = Map.get(step_run, :title, "Livrable ##{n} — brique livrée par #{role} (engineer)")
    body = Map.get(step_run, :pr_body, Texts.pr_body(n, role))

    # La PR est ouverte AU NOM DE L'ENG (token de rôle, `as_role`), pas du compte système :
    # l'auteur de la PR sur la forge = Engineer (l'eng a fait le boulot). Token absent → fallback
    # système loggué (RoleToken, honnête-dégradé). C'est le SYSTÈME qui poste avec le token de
    # rôle, jamais le pod (forge-aveugle).
    with {:ok, sha} <- step1_publish(step_run, deliverable),
         {:ok, pr} <-
           open_pr_step(
             forge,
             repo,
             head,
             base,
             title,
             body,
             ForgeClient.as_role(forge_opts, role)
           ) do
      # La PR livrable ouverte = l'issue ENTRE en review (lifecycle humain ; mutex retire stage/build).
      # Best-effort (affichage) : la review/merge procèdent via la PR quoi qu'il arrive. Système-side
      # (forge_opts, pas as_role) : les stage/* sont gérés par lcars-system (WS1). Le poller ne relit plus
      # get_route sur cette issue (PR-backed → skip lease.ex:209), donc stage/* y est purement humain.
      _ = forge.set_stage(repo, n, Fleet.Pilot.Labels.stage_review(), forge_opts)
      Logger.info("StepRunCompleter: ##{n} #{role} → PR ##{pr} (head=#{head}, sha=#{sha})")
      {:ok, %{commit_sha: sha, pr_number: pr}}
    end
  end

  defp open_pr_step(forge, repo, head, base, title, body, forge_opts) do
    case forge.open_pr(repo, head, base, title, Keyword.put(forge_opts, :body, body)) do
      {:ok, pr} -> {:ok, pr}
      {:error, reason} -> {:error, {:open_pr, reason}}
    end
  end

  @doc """
  **PR-natif** — verdict de juge → **review native** sur la PR. Remplace le comment
  `[step_run:role:sha]` maison : le verdict de gate vit comme review Gitea (APPROVED / REQUEST_CHANGES),
  traçable, lisible sans query custom. C'est le DOMICILE durable du verdict.

  `step_run` : `:repo`, `:pr_number`, `:role`, `:review_event` (`:approve` | `:request_changes` |
  `:comment`), `:review_body` (optionnel, défaut généré du rôle + verdict).
  Returns `{:ok, :reviewed}` | `{:error, {:review, reason}}`.
  """
  @spec record_review(map(), keyword()) :: {:ok, :reviewed} | {:error, {:review, term()}}
  def record_review(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    pr = Map.fetch!(step_run, :pr_number)
    event = Map.fetch!(step_run, :review_event)

    body =
      Map.get(step_run, :review_body, Texts.review_body(Map.get(step_run, :role, "juge"), event))

    # La review native est postée AU NOM DU JUGE (token de rôle, `as_role`) : sur la forge,
    # l'auteur de la review = qualifier/reviewer (avatar/traça honnête), pas le compte système. Token
    # absent → fallback système loggué (RoleToken, honnête-dégradé). Le pod n'a pas de token ;
    # c'est le SYSTÈME qui poste la review en son nom (le pod reste forge-aveugle).
    # NB `ForgeClient.post_review/5` rend `:ok` (pas `{:ok, _}`) sur succes — matcher les deux
    # (un seam test peut rendre l'un ou l'autre ; le contrat reel = `:ok`).
    case forge.post_review(
           repo,
           pr,
           event,
           body,
           ForgeClient.as_role(forge_opts, Map.get(step_run, :role))
         ) do
      :ok -> {:ok, :reviewed}
      {:ok, _} -> {:ok, :reviewed}
      {:error, reason} -> {:error, {:review, reason}}
    end
  end

  @doc """
  **PR-natif** — PROMOTE : merge la PR en **fast-forward-only**. C'est le terminal `:pass`
  du dernier step — auto-close de l'issue via `Closes #N`. Sous bail serial + funnel append-only,
  la feature est descendante linéaire de `main` → FF garanti. Échec FF = invariant serial violé
  (deux branches sur le même code) → fail-loud `{:merge, _}`, PAS un conflit à résoudre.

  `step_run` : `:repo`, `:pr_number`. Returns `{:ok, :promoted}` | `{:error, {:merge, reason}}`.
  """
  @spec promote(map(), keyword()) :: {:ok, :promoted} | {:error, {:merge, term()}}
  def promote(step_run, opts \\ []) when is_map(step_run) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    pr = Map.fetch!(step_run, :pr_number)
    issue_n = Map.fetch!(step_run, :issue_number)
    producer = producer_of(Map.get(step_run, :producer_branch))

    # Sceau UNIQUE : commentaire gatekeeper + merge signé gatekeeper — EXACTEMENT le même chemin que
    # `StepDispatcher.promote_pr`. La signature gatekeeper est posée EN INTERNE par `seal_and_merge`
    # (writer unique `GatekeeperSeal.as_gatekeeper/1`) : ce terminal `:promote` (ex. après escalade)
    # ne peut pas merger en token système brut sans commentaire (merge attribué `lcars-system`).
    case Fleet.Pilot.GatekeeperSeal.seal_and_merge(forge, repo, pr, issue_n, producer, forge_opts) do
      :ok -> {:ok, :promoted}
      {:error, {:merge, _}} = err -> err
    end
  end

  # Producteur extrait du `producer_branch` (`lcars/issue-N-<producteur>`) pour le commentaire de sceau.
  # Le format de la feature-branch a une AUTORITÉ UNIQUE : `ForgeProtocol.parse_feature_branch/1` (collée à
  # son builder `feature_branch/2`). On délègue le parse au lieu d'une regex locale → plus de drift possible.
  # Fallback `engineer` si la branche n'est pas une feature-branch fleet (head non reconnu / absent).
  defp producer_of(branch) when is_binary(branch) do
    case ForgeProtocol.parse_feature_branch(branch) do
      {:ok, {_n, producer}} -> producer
      :error -> "engineer"
    end
  end

  defp producer_of(_), do: "engineer"

  @doc """
  **PR-natif — orchestrateur de fin-de-step-run.** Compose les primitives PR
  (`open_deliverable_pr`/`record_review`/`promote`) + le routage selon l'`intent` de gate.
  Remplace la sequence maison `complete/2` (push `lcars/issue-N-role` + comment `[step_run:role:sha]` +
  state + assignee/close + unlock) sur le happy-path : la PR devient le domicile review+promote,
  la forge auto-close l'issue au merge (`Closes #N`).

  Le step_run est **deja resolu** par l'appelant (`StepRunConsumer` connait la workflow_map + le `deliverable_mode`) :

    * `:pr_role` — `:producer` (role git_native → pousse le code, ouvre la PR) | `:judge`
      (role payload → review la PR du producteur).
    * `:intent` — decision de gate : `:advance` (step suivant) | `:promote` (terminal) |
      `:rework` (rebond).
    * `:producer_branch` — head de la PR a reviewer (`lcars/issue-N-<producteur>`) ; requis pour
      un juge (lookup de la PR). Producteur : sa propre `deliverable_opts.target_branch` sert de head.
    * `:next_assignee` — role suivant (`:advance`) ou role de rebond (`:rework`) ; `nil` en terminal.

  ## Routage (switch review-request)

  Le trigger du step suivant = la review-request native (`request_review`), plus `set_assignee` :
  le producteur reste assigne (Entry), les juges sont dispatches via la PR (`dispatch_review`). La
  position workflow_map (`post_route`) reste gravee sur l'issue. Le verrou `lcars-in-flight` est leve en
  DERNIER sur le bon numero : producteur -> l'ISSUE (verrou pose par `dispatch_issue`) ; juge -> la
  PR (verrou pose par `dispatch_review`).

  Returns `{:ok, :promoted | :review_requested | :rework_requested}` | `{:error, {step, reason}}`.
  """
  @spec complete_pr(map(), keyword()) ::
          {:ok, :promoted | :review_requested | :rework_requested | :reviewed}
          | {:error, {atom(), term()}}
  def complete_pr(step_run, opts \\ []) when is_map(step_run) do
    case Map.fetch!(step_run, :pr_role) do
      :producer -> complete_producer(step_run, opts)
      :judge -> complete_judge(step_run, opts)
    end
  end

  # Producteur (engineer, git_native) : pousse le livrable + ouvre la PR, PUIS route. Sur un rework
  # de son PROPRE gate (code rejete), pas de PR — re-dispatch direct (le producteur recommence).
  defp complete_producer(%{intent: :rework} = step_run, opts), do: route(step_run, nil, opts)

  defp complete_producer(step_run, opts) do
    with {:ok, %{pr_number: pr}} <- open_deliverable_pr(step_run, opts) do
      # Émissions ANNEXES best-effort (voix eng PR+issue, slot-freeze deliverable.published) —
      # discard par contrat : la séquence ne dépend d'aucun retour (cf. Emissions).
      _ = Emissions.post_eng_summary(step_run, pr, opts)
      _ = Emissions.deliverable_published(step_run, pr)
      route(step_run, pr, opts)
    end
  end

  # Juge (payload) : retrouve la PR du producteur, enregistre la review native (verdict→event),
  # PUIS route. La review native EST le domicile durable du verdict (vs le comment maison).
  defp complete_judge(step_run, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = Map.fetch!(step_run, :repo)
    base = Map.get(step_run, :base_branch, "main")
    head = Map.get(step_run, :producer_branch)

    case resolve_pr(forge, repo, head, base, forge_opts) do
      {:ok, pr} ->
        # Juge de LIVRABLE (la PR existe) : verdict tracé en review native + route PR (request next / merge).
        with {:ok, :reviewed} <- record_review(review_step_run(step_run, pr), opts) do
          route(step_run, pr, opts)
        end

      {:error, {:pr_lookup, :no_producer_branch}} = err ->
        # Juge de BRIEF (judge_target:brief) : PRÉ-PR, donc pas de PR ni de review native → le
        # verdict se trace en COMMENTAIRE issue et l'avance est ISSUE-LEVEL (grave la route → le poller
        # dispatche le step suivant). Réutilise `complete` (la MÊME complétion issue-level que
        # close_with_trace : publish sauté via deliverable_opts nil + step_run_sha). Tout AUTRE juge sans PR =
        # erreur (un livrable était attendu) → fail-loud (jamais un merge sur PR introuvable).
        if Map.get(step_run, :judge_target) == "brief" do
          step_run
          |> Map.merge(%{deliverable_opts: nil, step_run_sha: "brief-verdict"})
          |> complete(opts)
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

  defp review_step_run(step_run, pr) do
    # Un juge no-workflow_map porte `:review_event` (mappé du gate-decision continue/abandon par
    # StepRunConsumer). À défaut (workflow_map), on dérive de l'INTENT via la TABLE UNIQUE
    # `Verdict.review_event/1` (autorité du mapping token→review-event, fail-closed : seuls
    # `:advance`/`:promote` approuvent, tout le reste — dont un intent inconnu — bloque en
    # REQUEST_CHANGES ; jamais d'approbation par omission). Le `:review_event` explicite prime.
    # Le `:review_body` (optionnel) prime sur le corps généré.
    event =
      Map.get(step_run, :review_event) ||
        Fleet.Pilot.StepRunConsumer.Verdict.review_event(Map.fetch!(step_run, :intent))

    step_run
    |> Map.put(:pr_number, pr)
    |> Map.put(:review_event, event)
  end

  # Routage commun selon l'intent. Le trigger du step suivant = la review-request native
  # (`request_review`), plus `set_assignee` : le producteur reste assigne (Entry), les juges
  # sont dispatches via la PR (`dispatch_review`). `post_route` (position workflow_map) RESTE sur l'issue.
  # `lcars-in-flight` leve en DERNIER sur le bon numero : producteur -> l'ISSUE (verrou pose par
  # dispatch_issue) ; juge -> la PR (verrou pose par dispatch_review). `pr` = nil seulement sur un
  # rework producteur (pas de PR).
  #   :promote -> merge FF (la PR `Closes #N` ferme l'issue), unlock ;
  #   :advance -> request_review(next) + post_route, unlock ;
  #   :rework  -> post_route(rebond), unlock. Re-dispatch : producteur via l'assignee Entry conserve
  #               (pas de PR encore) ; juge -> re-spawn producteur sur changes-requested.
  defp route(%{intent: :promote} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    # Transmet issue_number + producer_branch à `promote` (le sceau gatekeeper en a besoin pour le
    # commentaire de fin) ; réduire le step_run à {repo, pr_number} mergerait sans trace.
    promote_step_run = %{
      repo: step_run.repo,
      pr_number: pr,
      issue_number: step_run.issue_number,
      producer_branch: Map.get(step_run, :producer_branch)
    }

    with {:ok, :promoted} <- promote(promote_step_run, opts),
         {:ok, _} <- unlock(forge, step_run.repo, lock_number(step_run, pr), forge_opts) do
      {:ok, :promoted}
    end
  end

  defp route(%{intent: :advance} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = step_run.repo
    next = Map.fetch!(step_run, :next_assignee)

    with :ok <- request_review_step(forge, repo, pr, next, forge_opts),
         {:ok, _} <-
           post_route_if_present(forge, repo, step_run.issue_number, step_run, forge_opts, :route),
         {:ok, _} <- unlock(forge, repo, lock_number(step_run, pr), forge_opts) do
      {:ok, :review_requested}
    end
  end

  defp route(%{intent: :rework} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = step_run.repo

    with {:ok, _} <-
           post_route_if_present(forge, repo, step_run.issue_number, step_run, forge_opts, :route),
         {:ok, _} <- unlock(forge, repo, lock_number(step_run, pr), forge_opts) do
      {:ok, :rework_requested}
    end
  end

  # Producteur SANS workflow_map (single-brique) : la PR est ouverte (`complete_producer`) → on met
  # les JUGES (`:reviewer_roles`, défaut qualifier+reviewer) en `requested_reviewers` (le poller
  # `dispatch_review` les spawn un à un), on ASSIGNE l'HUMAIN à la PR (voir quel humain a
  # drivé), puis on lève le verrou de l'ISSUE (la PR ouverte fait skip l'issue côté poller via
  # `pulls_issue_ids`). PAS de merge ici : le merge est piloté par l'état-PR (dispatch_review, quand
  # tous les juges ont approuvé). Branch-protection OFF en dev → LCARS agrège, interim.
  defp route(%{intent: :review} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = step_run.repo

    # Unlock DES DEUX numéros (idempotent : remove_label no-op si absent). 1re livraison → le verrou est
    # sur l'ISSUE (posé par `dispatch_issue`) ; RE-livraison de rework → le verrou est sur la PR (posé
    # par `dispatch_review` :rework). On lève les deux pour ne stuck ni l'un ni l'autre.
    with :ok <- request_reviews_step(forge, repo, pr, Roles.reviewer_roles(opts), forge_opts),
         {:ok, _} <- assign_human_step(forge, repo, pr, forge_opts),
         {:ok, _} <- unlock(forge, repo, step_run.issue_number, forge_opts),
         {:ok, _} <- unlock(forge, repo, pr, forge_opts) do
      {:ok, :review_requested}
    end
  end

  # Juge SANS workflow_map : la review native a déjà été postée par `complete_judge` (`record_review`,
  # signée par le token du juge). Il ne reste qu'à lever le verrou de la PR. Le merge/rework est décidé
  # par le poller (`dispatch_review`, REVIEWS-DRIVEN : il lit la liste des reviews — verdict décisif par
  # juge — pas `requested_reviewers` que Gitea ne vide pas). Pas d'action sur `requested_reviewers`
  # (la DELETE est un no-op sur un juge ayant déjà reviewé).
  defp route(%{intent: :reviewed} = step_run, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    with {:ok, _} <- unlock(forge, step_run.repo, lock_number(step_run, pr), forge_opts) do
      {:ok, :reviewed}
    end
  end

  # Demande la review de TOUS les juges d'un coup (qualifier+reviewer en requested_reviewers).
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

  # Assigne l'HUMAIN commanditaire à la PR (comme le issue : voir QUEL humain a drivé les
  # agents). L'humain DRIVE, ne fait rien → il ne signe rien, mais il est l'assignee partout (traça du
  # driver). Assignee = champ de routing (pas d'authorship) → token système OK. Humain irrésoluble →
  # best-effort (le code EST livré) : log + on n'échoue pas le step_run.
  defp assign_human_step(forge, repo, pr, forge_opts) do
    case Fleet.Credentials.Human.current() do
      {:ok, login} ->
        case forge.set_assignee(repo, pr, login, forge_opts) do
          {:ok, _} = ok -> ok
          {:error, reason} -> {:error, {:assign_human, reason}}
        end

      {:error, reason} ->
        Logger.warning(
          "StepRunCompleter: humain commanditaire irrésoluble (#{inspect(reason)}) — PR ##{pr} non assignée"
        )

        {:ok, :no_human}
    end
  end

  # Espace deux écritures forge d'un même step_run d'au moins UNE SECONDE. Gitea horodate les events à
  # la seconde : deux écritures dans la même seconde tiennent une égalité de `created_at` que le feed
  # dashboard rend dans un ordre arbitraire (« logiquement avant, affiché après », constaté sur plusieurs
  # runs). On insère ce gap entre le commentaire HUMAIN (verdict) et l'écriture protocole suivante
  # (route/label) → le commentaire prend un `created_at` strictement antérieur → ordre de lecture cohérent.
  # Knob `:fleet_pilot, :step_run_write_spacing_ms` (défaut 2000 ; 0 en test → pas de sleep). Seam `:sleeper`
  # (test). NB : bloque brièvement le consumer (run_completion sync) — assumé : un step_run est rare et bloque
  # déjà sur le push + les écritures HTTP ; 2s achète une traça honnête (décision user).
  defp space_writes(opts) do
    case Application.get_env(:fleet_pilot, :step_run_write_spacing_ms, 2000) do
      ms when is_integer(ms) and ms > 0 -> (opts[:sleeper] || (&Process.sleep/1)).(ms)
      _ -> :ok
    end

    :ok
  end

  # Verrou a lever : producteur -> l'issue (verrou pose par dispatch_issue) ; juge -> la PR (verrou
  # pose par dispatch_review). Un rework producteur (pr nil) tombe sur l'issue.
  defp lock_number(%{pr_role: :judge}, pr) when is_integer(pr), do: pr
  defp lock_number(%{issue_number: n}, _pr), do: n

  # Grave la POSITION workflow_map [lcars-route:p:s] sur l'issue (lue par StepDispatcher/dispatch_review
  # pour identifier le step du juge : l'assignee/le reviewer seul ne l'identifie pas, un role peut
  # etre sur N steps). Reste (autorite de navigation) ; seul le TRIGGER (set_assignee) est remplace
  # par la review-request. Grave si workflow_map+next_step presents (sinon 1-step/terminal, pas de route).
  # Autorite UNIQUE du post_route pour les DEUX sequences (PR-native `route` ET maison `step4_route`).
  # `error_tag` : etiquette d'erreur de la sequence appelante — `:route` cote PR-native (via `route`),
  # `:reassign` cote maison (via `step4_route`). Chaque sequence distingue SON echec de post_route, donc
  # seule l'etiquette est parametree (logique commune, les deux comportements d'erreur sont preserves).
  defp post_route_if_present(forge, repo, n, step_run, forge_opts, error_tag) do
    case {Map.get(step_run, :workflow_map), Map.get(step_run, :next_step)} do
      {p, s} when is_binary(p) and is_binary(s) ->
        case forge.post_route(repo, n, p, s, forge_opts) do
          {:ok, _} = ok -> ok
          {:error, reason} -> {:error, {error_tag, reason}}
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

  # Retire le verrou `lcars-in-flight` — leve en DERNIER dans les DEUX sequences (nominale `complete`
  # et PR-native `route`) : un crash avant ce point laisse le verrou pose → le poller ne re-spawn pas →
  # la recovery rejoue (remove_label idempotent). Autorite UNIQUE du unlock pour les deux chemins.
  defp unlock(forge, repo, n, forge_opts) do
    case forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:unlock, reason}}
    end
  end

  # ── Étape 1 : commit + push livrable (ou step_run_sha fourni si pas de git) ──────
  defp step1_publish(step_run, deliverable) do
    case Map.get(step_run, :deliverable_opts) do
      nil ->
        case Map.get(step_run, :step_run_sha) do
          sha when is_binary(sha) and sha != "" -> {:ok, sha}
          _ -> {:error, {:publish, :no_deliverable_no_step_run_sha}}
        end

      d_opts when is_map(d_opts) ->
        case deliverable.publish(d_opts) do
          {:ok, %{commit_sha: sha}} -> {:ok, Map.get(step_run, :step_run_sha, sha)}
          {:error, reason} -> {:error, {:publish, reason}}
        end
    end
  end

  # ── Étape 2 : comment signé [step_run:role:sha], dédup ──────────────────────────
  # La signature ET le bloc result viennent de ForgeProtocol (vocab pur, co-localisés avec leurs
  # parseurs `step_run_marker?` / `parse_result_block`). On NE passe PAS par le seam `forge`
  # (un stub ne doit pas pouvoir désynchroniser le format du parseur réel).
  #
  # NB `:outputs` : embarque le `result_K` du step qui finit → lisible sans query séparée
  # (recovery, contexte). StepRunConsumer ne pose plus `:outputs` (le cas « avance vers un
  # gatekeeper-step » n'existe plus) → seam générique, inactif côté StepRunConsumer
  # mais conservé (autres appelants / extensibilité).
  defp step2_comment(forge, repo, n, role, sha, step_run, forge_opts) do
    signature = ForgeProtocol.step_run_marker(role, sha)

    body =
      Map.get(step_run, :comment_body, Texts.step_run_comment(role, sha)) <>
        ForgeProtocol.result_block(Map.get(step_run, :outputs)) <> "\n\n" <> signature

    # Le comment signé du step_run est AU NOM DU RÔLE qui finit (`as_role` : verdict du consultant /
    # livrable de l'eng → auteur forge = le rôle, pas le compte système ; même geste que la PR/review/sceau).
    case forge.post_comment(
           repo,
           n,
           body,
           forge_opts |> ForgeClient.as_role(role) |> Keyword.put(:dedup_signature, signature)
         ) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:comment, reason}}
    end
  end

  # ── Étape 4 : assignee suivant OU close (1-step terminal) ─────────────────
  # (Pas d'étape 3 « PATCH state:* » : l'état vit dans la route-comment. N° de step conservés.)
  # Reassign : grave la ROUTE du step suivant AVANT le PATCH assignee — le poller
  # ne doit voir le nouvel assignee qu'avec sa position workflow_map déjà posée (sinon le spawn
  # suivant ne saurait pas quel step il est). post_route idempotent (dédup marqueur).
  defp step4_route(forge, repo, n, step_run, forge_opts) do
    case Map.get(step_run, :next_assignee) do
      nil ->
        case forge.close_issue(repo, n, forge_opts) do
          {:ok, _} -> {:ok, :completed}
          {:error, reason} -> {:error, {:close, reason}}
        end

      next when is_binary(next) ->
        # AVANCE = grave la route du step suivant. PLUS de `set_assignee(next)` — l'assignee
        # reste l'HUMAIN (traça) ; le rôle du next step (`next`) est dérivé de la route au dispatch
        # (`StepDispatcher.workflow_map_role`), pas de l'assignee. `next` (next_role présent) distingue
        # AVANCE vs terminal (nil → close).
        # `post_route_if_present(..., :reassign)` enrobe deja l'erreur en `{:reassign, reason}` (le tag
        # de CETTE sequence) → on la propage telle quelle (ne PAS re-enrober, sinon double `{:reassign, ...}`).
        case post_route_if_present(forge, repo, n, step_run, forge_opts, :reassign) do
          {:ok, _} ->
            Logger.debug(
              "StepRunCompleter advance #{repo}##{n} → next step role=#{next} (route gravée, assignee=humain inchangé)"
            )

            {:ok, :reassigned}

          {:error, _} = err ->
            err
        end
    end
  end
end
