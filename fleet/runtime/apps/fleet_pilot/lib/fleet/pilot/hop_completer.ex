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
    3. **PATCH `state:*`** — `set_state_label` (DELETE ancien + PUT nouveau).
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
    * `:state_label` — label `state:*` à poser (défaut `"state:delivered"`)
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
          optional(:state_label) => String.t(),
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
    state_label = Map.get(hop, :state_label, Labels.delivered())

    with {:ok, sha} <- step1_publish(hop, deliverable),
         {:ok, _} <- step2_comment(forge, repo, n, role, sha, hop, forge_opts),
         {:ok, _} <- step3_state(forge, repo, n, state_label, forge_opts),
         {:ok, routed} <- step4_route(forge, repo, n, hop, forge_opts),
         {:ok, _} <- step5_unlock(forge, repo, n, forge_opts) do
      Logger.info(
        "HopCompleter: #{repo}##{n} role=#{role} sha=#{sha} → #{routed} (state=#{state_label})"
      )

      {:ok, routed}
    end
  end

  @awaits_human_label Labels.awaits_human()

  @doc """
  Fin-de-hop ALTERNATIVE (A2.3b, DN `gatekeeper-forge-encoding-v2` §3/§6) : un verdict
  gatekeeper **humain** (`escalate_user`/`halt_wait_input`/`redirect`/absent/invalide).
  Le SYSTÈME pose `lcars-awaits-human` + retire le verrou ; NE close PAS, NE reassign PAS.
  L'issue attend une action humaine **via l'arch** (`convention-tickets-gitea-v2` §7/§8) ;
  le poller la **SKIP** (`StageDispatcher.decide` → `:awaits_human`).

  Pas de livrable git ici (le verdict vit dans le comment signé ; `verdict.json` =
  item `submit_result` séparé). Ordre : comment → `lcars-awaits-human` → unlock (DERNIER,
  même principe §5 : un crash laisse le verrou → poller skip → recovery rejoue,
  idempotent via dédup comment + add/remove label idempotents).

  `hop` : `:repo`, `:issue_number`, `:role`, `:decision`. Returns `{:ok, :awaiting_human}`
  | `{:error, {:await_human, reason}}`.
  """
  @spec await_human(map(), keyword()) :: {:ok, :awaiting_human} | {:error, {:await_human, term()}}
  def await_human(hop, opts \\ []) when is_map(hop) do
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
        "Verdict du juge **#{role}** : `#{inspect(decision)}` → escalade humaine."

    body =
      lead <> " L'issue attend une action via l'arch (`lcars-awaits-human`).\n\n" <> signature

    with {:ok, _} <-
           forge.post_comment(repo, n, body, Keyword.put(forge_opts, :dedup_signature, signature)),
         {:ok, _} <- forge.add_label(repo, n, @awaits_human_label, forge_opts),
         {:ok, _} <- forge.remove_label(repo, n, @in_flight_label, forge_opts) do
      Logger.info(
        "HopCompleter: #{repo}##{n} role=#{role} → awaiting_human (decision=#{inspect(decision)})"
      )

      {:ok, :awaiting_human}
    else
      {:error, reason} -> {:error, {:await_human, reason}}
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
    base = Map.get(hop, :base_branch, "main")
    head = Map.fetch!(Map.fetch!(hop, :deliverable_opts), :target_branch)
    title = Map.get(hop, :title, "Livrable ##{n} (#{Map.get(hop, :role, "engineer")})")
    body = Map.get(hop, :pr_body, "Closes ##{n}")

    with {:ok, sha} <- step1_publish(hop, deliverable),
         {:ok, pr} <- open_pr_step(forge, repo, head, base, title, body, forge_opts) do
      Logger.info("HopCompleter: ##{n} engineer → PR ##{pr} (head=#{head}, sha=#{sha})")
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

    # NB `ForgeClient.post_review/5` rend `:ok` (pas `{:ok, _}`) sur succes — matcher les deux
    # (un seam test peut rendre l'un ou l'autre ; le contrat reel = `:ok`).
    case forge.post_review(repo, pr, event, body, forge_opts) do
      :ok -> {:ok, :reviewed}
      {:ok, _} -> {:ok, :reviewed}
      {:error, reason} -> {:error, {:review, reason}}
    end
  end

  defp default_review_body(hop, event) do
    verdict =
      case event do
        :approve -> "PASS"
        :request_changes -> "REQUEST_CHANGES"
        _ -> "comment"
      end

    "Verdict **#{Map.get(hop, :role, "juge")}** : #{verdict}."
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

    # NB `ForgeClient.merge_pr/3` rend `:ok` (pas `{:ok, _}`) sur succes — matcher les deux.
    case forge.merge_pr(repo, pr, forge_opts) do
      :ok -> {:ok, :promoted}
      {:ok, _} -> {:ok, :promoted}
      {:error, reason} -> {:error, {:merge, reason}}
    end
  end

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

  ## Pont transitionnel (increment 4 le retire)

  Tant que le **poller** dispatche sur l'`assignee` de l'issue (pas encore sur la review-request),
  on grave `set_assignee` (`:advance`/`:rework`) **en parallele** de la review-request native, et on
  leve le verrou `lcars-in-flight` en dernier. Le switch poller→review-request = increment 4.

  Returns `{:ok, :promoted | :review_requested | :rework_requested}` | `{:error, {step, reason}}`.
  """
  @spec complete_pr(map(), keyword()) ::
          {:ok, :promoted | :review_requested | :rework_requested} | {:error, {atom(), term()}}
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
      route(hop, pr, opts)
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

    with {:ok, pr} <- resolve_pr(forge, repo, head, base, forge_opts),
         {:ok, :reviewed} <- record_review(review_hop(hop, pr), opts) do
      route(hop, pr, opts)
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
    hop
    |> Map.put(:pr_number, pr)
    |> Map.put(:review_event, review_event_for_intent(Map.fetch!(hop, :intent)))
  end

  # Verdict de gate → event de review native. `:rework` (gate fail) = REQUEST_CHANGES ; `:advance`/
  # `:promote` (gate pass) = APPROVED. Le `:review_body` (optionnel) prime sur le corps genere.
  defp review_event_for_intent(:rework), do: :request_changes
  defp review_event_for_intent(_), do: :approve

  # Routage commun selon l'intent (`pr` = nil seulement sur un rework producteur — pas de PR).
  #   :promote → merge FF (la PR `Closes #N` ferme l'issue), unlock ;
  #   :advance → request_review(next) [+ pont set_assignee], unlock ;
  #   :rework  → re-dispatch (pont set_assignee vers le rebond), unlock.
  # `lcars-in-flight` leve en DERNIER (pont poller, meme garantie crash que §5).
  defp route(%{intent: :promote} = hop, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])

    with {:ok, :promoted} <- promote(%{repo: hop.repo, pr_number: pr}, opts),
         {:ok, _} <- unlock(forge, hop.repo, hop.issue_number, forge_opts) do
      {:ok, :promoted}
    end
  end

  defp route(%{intent: :advance} = hop, pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = hop.repo
    n = hop.issue_number
    next = Map.fetch!(hop, :next_assignee)

    with :ok <- request_review_step(forge, repo, pr, next, forge_opts),
         {:ok, _} <- bridge_assignee(forge, repo, n, next, forge_opts),
         {:ok, _} <- unlock(forge, repo, n, forge_opts) do
      {:ok, :review_requested}
    end
  end

  defp route(%{intent: :rework} = hop, _pr, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    forge_opts = Keyword.get(opts, :forge_opts, [])
    repo = hop.repo
    n = hop.issue_number
    rebound = Map.fetch!(hop, :next_assignee)

    with {:ok, _} <- bridge_assignee(forge, repo, n, rebound, forge_opts),
         {:ok, _} <- unlock(forge, repo, n, forge_opts) do
      {:ok, :rework_requested}
    end
  end

  defp request_review_step(forge, repo, pr, reviewer, forge_opts) do
    case forge.request_review(repo, pr, [reviewer], forge_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_review, reason}}
    end
  end

  # Pont transitionnel (increment 4 le retire) : le poller dispatche encore sur l'assignee de l'issue.
  defp bridge_assignee(forge, repo, n, login, forge_opts) do
    case forge.set_assignee(repo, n, login, forge_opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:reassign, reason}}
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

  # ── Étape 3 : PATCH state:* ────────────────────────────────────────────────
  defp step3_state(forge, repo, n, state_label, forge_opts) do
    case forge.set_state_label(repo, n, state_label, forge_opts) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:state, reason}}
    end
  end

  # ── Étape 4 : assignee suivant (A2) OU close (1-stage terminal) ────────────
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
        with {:ok, _} <- maybe_post_route(forge, repo, n, hop, forge_opts),
             {:ok, _} <- forge.set_assignee(repo, n, next, forge_opts) do
          {:ok, :reassigned}
        else
          {:error, reason} -> {:error, {:reassign, reason}}
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
