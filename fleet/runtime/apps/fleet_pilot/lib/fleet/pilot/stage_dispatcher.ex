defmodule Fleet.Pilot.StageDispatcher do
  @moduledoc """
  Dispatch `ticket assigné → spawn le rôle de la carte` du modèle forge-state-machine (DN
  `orchestration/forge-state-machine.md` §1). Le poller voit un ticket **assigné-à-moi** (scoping
  multi-user forge-side, #5.2 D1), non verrouillé, et le pousse à son stage courant.

  ## Décision (`decide/1`) — PORTE pure (#5.2 D2)

  À partir du payload d'une issue Gitea : `:engage` (procéder) | `{:skip, reason}` (`:in_flight` verrou posé,
  `:awaits_arch` verrou humain). decide ne fait QUE la porte — pas d'ownership (scoping forge-side amont),
  pas de rôle ni de load (le RÔLE vient de la POSITION carte, via `carte_role` ; voir Effets).

  ## Effets (`dispatch_issue/2`)

  Sur `:engage` : résout projet + route, puis (#5.2 D2) :
    * **route absente** (issue routeless — create_ticket ne grave plus, ou ticket humain brut) →
      `ensure_carte_or_onboard` grave la **carte par défaut** (mandate-gate) → `{:skipped, :onboarded}`
      (on défère ; le tick suivant la voit routée). C'est l'ENTRÉE système : create_ticket crée, le poller route.
    * **route présente** → `carte_role` dérive `{role, profile, stage_spec}` de la POSITION carte (PAS de
      producteur en dur — la route décide ; route absente à ce point = anomalie → fail-loud, jamais l'eng en
      silence), puis l'**ordre canonique du spawn** (DN §6, label `lcars-in-flight` AVANT pod, sinon double-spawn).

  Les juges sont dispatchés PR-driven via `dispatch_review` (requested_reviewers). Les modules
  `:forge_client` / `:loader` / `:carte_loader` / `:spawner` sont des **seams** (défauts = modules réels).
  """

  require Logger

  # F072 : vocabulaire protocole = source unique Fleet.Pilot.Labels (constantes compile-time).
  @in_flight_label Fleet.Pilot.Labels.in_flight()
  @awaits_arch_label Fleet.Pilot.Labels.awaits_arch()

  @type decision :: :engage | {:skip, atom()}

  @doc """
  Décision PURE (porte) : payload issue → `:engage` | `{:skip, reason}`. #5.2 D2 — decide ne fait QUE la
  porte : verrou `lcars-in-flight` / `lcars-awaits-arch` → skip ; sinon → `:engage` (proceder). Le rôle ET
  l'action (spawn vs onboard) sont décidés EN AVAL (`dispatch_issue`) — d'où `:engage` et pas `:spawn`. Le SCOPING
  (forge-side, en amont) et le ROUTAGE (route → rôle, via `carte_role`/onboard dans `dispatch_issue`) ne
  sont PAS ici — decide ne charge rien et ne décide pas le rôle.
  """
  @spec decide(map()) :: decision()
  def decide(payload) when is_map(payload) do
    labels =
      payload
      |> Map.get("issue", payload)
      |> Map.get("labels", [])
      |> Enum.map(& &1["name"])

    cond do
      @in_flight_label in labels ->
        {:skip, :in_flight}

      # A2.3b : verrou HUMAIN (verdict gatekeeper escalate/halt/redirect, ou anomalie A2.6). L'issue attend
      # une action via l'arch ; le poller NE re-dispatche PAS (sinon boucle de jugement après l'unlock).
      @awaits_arch_label in labels ->
        {:skip, :awaits_arch}

      true ->
        :engage
    end
  end

  @doc """
  Dispatch effectif d'une issue : `decide/1` puis, sur `:engage`, résout projet+route et soit ONBOARDE
  (routeless → grave la carte par défaut → skip, D2), soit dérive le rôle de la carte (`carte_role`) et
  applique l'ordre canonique du spawn (verrou → pod → enqueue → wake, `spawn_stage`). Idempotent.

  `opts` : `:repo` (obligatoire), `:forge_opts` (passé au ForgeClient), + seams
  `:forge_client` / `:loader` / `:carte_loader` / `:spawner` / `:task_queue` / `:clock` (défauts = modules réels).
  """
  @spec dispatch_issue(map(), keyword()) ::
          {:ok, {:spawned, pod_id :: String.t(), role :: String.t()}}
          | {:skipped, atom()}
          | {:error, term()}
  def dispatch_issue(payload, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    loader = Keyword.get(opts, :loader, Fleet.CapProfile)
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    task_queue = Keyword.get(opts, :task_queue, Fleet.TaskQueue)
    resolver = Keyword.get(opts, :project_resolver, &default_project_resolver/2)

    # #8 : chargeur de carte injectable (seam, comme les autres) — rend `carte_role` testable sans disque.
    carte_loader = Keyword.get(opts, :carte_loader, &Fleet.Pipeline.Loader.load!/1)

    case decide(payload) do
      {:skip, reason} ->
        {:skipped, reason}

      :engage ->
        issue = Map.get(payload, "issue", payload)
        number = issue["number"]
        repo = Keyword.fetch!(opts, :repo)
        forge_opts = Keyword.get(opts, :forge_opts, [])

        # PROJET + ROUTE résolus AVANT toute écriture forge (read-only) : un échec transitoire ne laisse pas
        # de verrou orphelin. project = base_sha pinné (F-03) ; route = (pipeline, stage) gravée (A2.1).
        # #5.2 D2 — ROUTELESS = pas encore onboardée (create_ticket ne grave plus) → `ensure_carte_or_onboard`
        # grave la carte par défaut + renvoie `{:onboarded, _}` → on DÉFÈRE (skip ; le tick suivant la voit
        # routée). Routée → `carte_role` dérive le rôle de la POSITION carte (PAS de producteur en dur ;
        # route absente à ce point = anomalie post-onboard → fail-loud, JAMAIS l'eng en silence).
        # F-S1-1 : route + carte pré-lues par le poller (classification du bail) → réutilisées via opts
        # (`resolve_route` / `:prefetched_carte`) au lieu d'un 2ᵉ get_route + 2ᵉ load carte. Absentes (tests,
        # autres callers) → lecture/chargement normaux (fallback).
        with {:ok, project} <- tag_err(resolver.(repo, opts), :project_resolution),
             {:ok, route} <-
               tag_err(resolve_route(opts, forge, repo, number, forge_opts), :route_resolution),
             {:ok, route} <-
               ensure_carte_or_onboard(forge, repo, number, route, carte_loader, forge_opts),
             {:ok, {role, profile, stage_spec}} <-
               tag_err(
                 carte_role(
                   route,
                   &loader.load/1,
                   carte_loader,
                   Keyword.get(opts, :prefetched_carte)
                 ),
                 :role_resolution
               ) do
          # BL-055 : pod_id DÉTERMINISTE STABLE keyé sur (issue, rôle) — PLUS de `-<ts>`. Le timestamp
          # rendait l'id unique par hop → re-spawn à chaque rework, l'eng pipe (long-lived) lingérait,
          # contexte perdu. Stable → un re-dispatch retombe sur le MÊME pod : s'il est vivant (eng pipe),
          # on le RE-MANDATE (garde son contexte), sinon on spawn. (Idempotence — cf. spawn_or_remandate.)
          # #25 : pod_id REPO-SCOPÉ via `Fleet.Pilot.PodId` (clé GLOBALE → désambiguïse cross-repo/run).
          # La branche reste repo-LOCALE (`lcars/issue-N-role`, branch_for/2) — pas de collision dans un
          # repo → NON scopée ; pod_id et branche construits indépendamment depuis (n, role). pod_id opaque
          # (jamais re-parsé) → seule exigence : tous les sites passent par le helper (format unique).
          pod_id = Fleet.Pilot.PodId.for_issue(repo, number, role)

          # F077/F078 : la FORME du mandat (worker exécutable | juge désamorcé) est lue du cap-profile
          # (`mandate_kind`), PAS d'un nom magique "gatekeeper" en ring2 (differentiation-par-catalogue).
          # Calculé UNE fois → sert au spawn-file ET au brief TaskQueue (que le pod pull via get_task).
          # Sans ça, enqueue_mandate ré-enqueuait `issue["body"]` brut → un juge pullait le mandat BUILD
          # exécutable au lieu du GateBrief → PASSE-9 recréé.
          mandate =
            build_mandate(
              profile,
              role,
              forge,
              repo,
              number,
              issue,
              forge_opts,
              route,
              stage_spec
            )

          spawn_opts =
            [
              mandate: mandate,
              pod_id: pod_id,
              rc_name: rc_name(repo, role),
              # #chantier monde-propre : nom de branche LOCALE parlant (titre du ticket sanitizé), pas
              # le pod_id. Sert à phase.ex → `feature/<slug>`.
              slug: feature_slug(issue)
            ]
            |> maybe_put_project(project)
            |> maybe_put_route(route)
            |> maybe_put_repo_id(resolve_repo_id(forge, repo, forge_opts))

          # #5.2 D3 — spawn LEAF partagé avec dispatch_by_verdicts (verrou → pod → enqueue → wake +
          # compensation). Producteur : verrou + ticket_id keyés sur l'ISSUE (number).
          log_ctx =
            "issue=#{repo}##{number} " <>
              "project=#{if(project, do: project["base_sha"], else: "none")} route=#{inspect(route)}"

          spawn_stage(
            %{
              forge: forge,
              spawner: spawner,
              task_queue: task_queue,
              repo: repo,
              forge_opts: forge_opts,
              # MA-17 — seam de recovery de wake (défaut = la vraie fn) threadé depuis opts.
              wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3)
            },
            pod_id,
            role,
            profile,
            mandate,
            spawn_opts,
            number,
            number,
            log_ctx
          )
        else
          {:onboarded, _stage} ->
            # #5.2 D2 — issue routeless onboardée sur la carte par défaut → on DÉFÈRE (skip ; le tick suivant
            # la voit routée → dispatch). Entrée système : create_ticket crée, le poller route.
            {:skipped, :onboarded}

          {:error, {phase, reason}} ->
            Logger.warning(
              "StageDispatcher: #{phase} issue=#{repo}##{number} → #{inspect(reason)} (skip, pas de verrou)"
            )

            {:error, {phase, reason}}
        end
    end
  end

  @doc """
  Dispatch PR-driven d'un JUGE (Corr.3 4-C, switch review-request). Une PR ouverte avec une review
  demandee (`requested_reviewers`) -> spawn le role juge pour la reviewer. Remplace le trigger
  assignee-issue pour les JUGES (le producteur reste issue-assignee-driven, via `dispatch_issue`).

  Le pipeline-state (route = position carte) reste sur l'ISSUE : `dispatch_review` remonte de
  `head.ref` (`lcars/issue-N-role`) au ticket et lit la route gravee. Le verrou `lcars-in-flight`
  est pose sur la PR (pas l'issue) : il empeche le re-spawn du juge entre le spawn et la review
  postee (apres quoi Gitea retire le reviewer de `requested_reviewers`). Idempotent (verrou PR +
  dedup du lock comment).

  `pr` : map Gitea (`number`, `head.ref`, `requested_reviewers`, `labels`). `opts` comme
  `dispatch_issue/2`. Returns `{:ok, {:spawned, pod_id, role}}` | `{:skipped, reason}` | `{:error, _}`.
  """
  @spec dispatch_review(map(), keyword()) ::
          {:ok, {:spawned, String.t(), String.t()}} | {:skipped, atom()} | {:error, term()}
  def dispatch_review(pr, opts) when is_map(pr) do
    ctx = %{
      forge: Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient),
      loader: Keyword.get(opts, :loader, Fleet.CapProfile),
      spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
      task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
      clock: Keyword.get(opts, :clock, &System.os_time/1),
      resolver: Keyword.get(opts, :project_resolver, &default_project_resolver/2),
      repo: Keyword.fetch!(opts, :repo),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      # MA-17 — seam de recovery de wake (défaut = la vraie fn) threadé depuis opts.
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      opts: opts
    }

    pr_number = pr["number"]
    head = get_in(pr, ["head", "ref"]) || ""
    head_sha = get_in(pr, ["head", "sha"])
    labels = Enum.map(Map.get(pr, "labels") || [], & &1["name"])

    # F-E8 — le SET des juges NE se lit PAS du seul `requested_reviewers` : Gitea altère ce champ de façon
    # NON FIABLE (un juge a pu en DISPARAÎTRE sans avoir voté → merge sur demi-jury, live PoC-7). Source
    # STABLE = les review-records (`pr_review_state.reviewers`, REQUEST_REVIEW inclus). On garde
    # `requested_reviewers` en UNION (défensif : un fraîchement-demandé pas encore dans les records). Logins↓.
    requested_field = pr |> Map.get("requested_reviewers") |> List.wrap() |> Enum.map(&login_of/1)

    # #5.2 D1 — pas de check d'ownership ici : le scoping PR est FORGE-SIDE en amont (list_open_pulls ne rend
    # QUE mes PR via /issues?type=pulls&assigned_by). dispatch_review ne fait que du dispatch de jugement.
    cond do
      @in_flight_label in labels ->
        {:skipped, :in_flight}

      # MA-01 (bug B) — l'ISSUE parente porte `lcars-awaits-arch` (escalade : verdict gatekeeper
      # escalate/halt/redirect, ou conflit non auto-résolu) → on NE re-dispatch PAS le juge (sinon churn :
      # re-spawn par tick, vu live). SYMÉTRIQUE de `decide/1` côté issue. Le SET vient du POLLER (issues déjà
      # listées au tick → `:awaits_arch_ids`, ZÉRO I/O ajouté) ; absent (autres callers/tests) → `MapSet.new()`
      # → comportement inchangé (back-compat). On lit le label sur l'ISSUE, pas sur la PR : c'est l'issue qui
      # gèle (l'escalade pose le verrou humain dessus), la PR n'en sait rien — d'où l'aveuglement d'origine.
      awaits_arch_issue?(head, opts) ->
        {:skipped, :awaits_arch}

      true ->
        # head_sha → verdicts COMMIT-SCOPÉS : une review sur un commit antérieur (REQUEST_CHANGES jamais
        # dismissé par Gitea au push) est PÉRIMÉE → son juge redevient `pending` → re-dispatché sur le code
        # courant (sinon rework infini, live #7).
        verdict_opts = Keyword.put(ctx.forge_opts, :head_sha, head_sha)

        case ctx.forge.pr_review_state(ctx.repo, pr_number, verdict_opts) do
          {:ok, %{verdicts: verdicts, reviewers: jury}} ->
            # F-E8 : SET des juges = union(requested_reviewers VOLATIL, review-records STABLES). Un juge
            # tombé de `requested_reviewers` sans voter reste dans le jury → `pending` → spawné, jamais un
            # merge sur demi-jury (cf. ForgeClient.pr_review_state).
            requested = Enum.uniq(requested_field ++ jury)
            dispatch_by_verdicts(requested, verdicts, pr_number, head, ctx)

          {:error, reason} ->
            {:error, {:review_state, reason}}
        end
    end
  end

  # MA-01 (bug B) — l'issue parente de la PR (déduite de `head.ref` = `lcars/issue-<n>-<role>`) attend-elle
  # l'arch ? Le SET `:awaits_arch_ids` est calculé par le poller (issues du tick, zéro I/O) et threadé via
  # opts ; défaut `MapSet.new()` (back-compat, autres callers). PR non-fleet (`:error`) → false (rien à skip).
  defp awaits_arch_issue?(head, opts) do
    ids = Keyword.get(opts, :awaits_arch_ids, MapSet.new())

    case Fleet.Pilot.ForgeClient.parse_feature_branch(head) do
      {:ok, {n, _role}} -> MapSet.member?(ids, n)
      :error -> false
    end
  end

  defp login_of(r), do: r |> Map.get("login", "") |> to_string() |> String.downcase()

  # ②.1d — aiguillage REVIEWS-DRIVEN (la source de vérité = les reviews postées, PAS `requested_reviewers`
  # que Gitea ne vide pas, live #6). Sans branch-protection : LCARS agrège (décision user). ORDRE :
  #   1. un juge demandé SANS verdict décisif → round actif → on le spawn (sérialisé par le verrou PR).
  #      Un juge déjà décisif (même encore listé dans requested_reviewers) n'est PAS re-spawné → fin de
  #      la boucle live #6.
  #   2. tous les demandés ont un verdict + au moins un `:changes_requested` → rework du producteur.
  #   3. tous les demandés ont APPROUVÉ → MERGE (scellé gatekeeper).
  #   4. aucun juge demandé → no_verdict (PR sans review-request, surfacé).
  defp dispatch_by_verdicts(requested, verdicts, pr_number, head, ctx) do
    pending = requested -- Map.keys(verdicts)

    cond do
      pending != [] ->
        dispatch_pr_role(:judge, pr_number, head, hd(pending), ctx)

      requested == [] ->
        {:skipped, :no_verdict}

      Enum.any?(Map.values(Map.take(verdicts, requested)), &(&1 == :changes_requested)) ->
        dispatch_rework(pr_number, head, ctx)

      true ->
        # F-PARALLEL-PR-CONFLICT : tous approuvé → MERGE. Si le merge échoue sur un CONFLIT (PR approuvée mais
        # `main` a avancé + même fichier édité), on ne remonte plus l'erreur sèche (= retry-à-l'infini avec un
        # sceau mensonger). On RÉSOUT (rebase producteur), borné par l'IncidentRegistry (récurrence → escalade arch).
        case promote_pr(pr_number, head, ctx) do
          {:error, {:merge, reason}} -> dispatch_conflict_resolution(pr_number, head, reason, ctx)
          other -> other
        end
    end
  end

  # Rework juge : la PR porte un verdict REQUEST_CHANGES courant (l'état a déjà été lu par
  # `dispatch_review` → pas de re-lecture ici) -> le PRODUCTEUR (role git_native de head.ref) reprend
  # pour corriger sur la même PR. Idempotent (verrou PR). NB transitionnel : le mandat ne porte pas
  # encore le feedback détaillé de la review (4-C-iv+).
  defp dispatch_rework(pr_number, head, ctx) do
    case Fleet.Pilot.ForgeClient.parse_feature_branch(head) do
      {:ok, {_n, producer_role}} ->
        dispatch_pr_role(:rework, pr_number, head, producer_role, ctx)

      :error ->
        {:skipped, :not_fleet_branch}
    end
  end

  # F-PARALLEL-PR-CONFLICT — merge KO sur conflit (PR approuvée, `main` avancé sous une PR parallèle touchant le
  # même fichier). Borné par l'IncidentRegistry (cross-session, work/ops) :
  #   1ʳᵉ occurrence → `:recorded` → dispatch le PRODUCTEUR en `:resolve_conflict` (rebase + résous ; le push
  #     rebasé invalide les vieilles reviews via head_sha → les juges re-valident le fusionné, gatekeeper scelle
  #     au tick suivant) ;
  #   récurrence → `{:escalated, _}` (résolution déjà tentée, conflit persiste) → ESCALADE ARCH. PAS de boucle.
  defp dispatch_conflict_resolution(pr_number, head, reason, ctx) do
    # MA-14 — le n° de PR est encodé DIGIT-FREE (base-26 a..z) DANS le subject. `IncidentRegistry.signature`
    # passe le subject par `normalize` (`~r/\d+/ → "N"`, PARTAGÉ pod/wake — on ne le touche PAS) : un `pr-8`
    # décimal devenait `pr-N` ≡ `pr-12` → après le 1er conflit d'un repo, TOUTE PR suivante en conflit était
    # vue « récurrente » → escaladée arch au lieu d'être résolue (neutralisait la résolution F-PARALLEL dès le
    # 2ᵉ ticket parallèle). En encodant le numéro en LETTRES (`pr-i` pour 8, `pr-m` pour 12), `normalize` ne
    # le collapse plus → la clé incident est DISTINCTE par PR. (Le repo, lui, peut porter des digits collapsés
    # par normalize : sans incidence — une session de conflits est dans UN repo, l'axe de distinction est la PR.)
    subject = "#{ctx.repo}#pr-#{encode_pr_letters(pr_number)}"

    # Reason STABLE pour le compteur : la dedup inclut la reason → un message http qui varie casserait le seuil.
    # Le détail réel (`reason`) va dans le commentaire d'escalade, pas dans la clé. Seam test : router vers un
    # IncidentRegistry nommé (async-safe) via `:incident_registry_server` ; absent (prod) → registry par défaut.
    reg_opts =
      case Keyword.get(Map.get(ctx, :opts, []), :incident_registry_server) do
        nil -> []
        server -> [server: server]
      end

    case Fleet.Pilot.IncidentRegistry.record_or_escalate(
           "merge-conflict",
           subject,
           "PR inmergeable (conflit de base)",
           reg_opts
         ) do
      :recorded ->
        case Fleet.Pilot.ForgeClient.parse_feature_branch(head) do
          {:ok, {_n, producer_role}} ->
            dispatch_pr_role(:resolve_conflict, pr_number, head, producer_role, ctx)

          :error ->
            {:skipped, :not_fleet_branch}
        end

      {:escalated, _} ->
        escalate_conflict_to_arch(pr_number, head, reason, ctx)
    end
  end

  # MA-14 — encode un n° de PR en LETTRES (base-26 bijective a..z) → DIGIT-FREE, donc INVISIBLE à `normalize`
  # (`~r/\d+/ → "N"`) côté IncidentRegistry. Bijectif (chaque numéro → une chaîne unique : 1→a … 26→z, 27→aa)
  # → deux PR distinctes ont des clés incident DISTINCTES (l'invariant que MA-14 RÉTABLIT pour F-PARALLEL).
  # Numéro ≤ 0 / non-entier (anomalie forge) → `"x"` constant (digit-free, ne crash pas la clé).
  defp encode_pr_letters(n) when is_integer(n) and n > 0, do: encode_pr_letters(n, [])
  defp encode_pr_letters(_), do: "x"

  defp encode_pr_letters(0, acc), do: List.to_string(acc)

  defp encode_pr_letters(n, acc) do
    rem0 = rem(n - 1, 26)
    encode_pr_letters(div(n - 1, 26), [?a + rem0 | acc])
  end

  # Conflit non auto-résolu (1 tentative déjà faite) → l'arch tranche. Commentaire signé gatekeeper (dédupliqué)
  # + verrou `lcars-awaits-arch` sur l'ISSUE → le poller la SKIP (hors-dispatch, plus de retry). Honnête : on ne
  # masque pas, on remonte au seul canal humain (l'arch).
  defp escalate_conflict_to_arch(pr_number, head, reason, ctx) do
    with {:ok, {issue_n, _producer}} <- parse_feature_branch_or_skip(head) do
      signature = "[merge-conflict-escalation:pr-#{pr_number}]"

      body =
        "**Architecte** — ⚠ Conflit de merge non auto-résolu sur la PR ##{pr_number} (issue ##{issue_n}) " <>
          "après une tentative de rebase+résolution (`#{inspect(reason)}`). Reprends : fais rebaser/résoudre la " <>
          "PR sur `main`, ou re-cadre. L'issue reste hors-dispatch tant que `lcars-awaits-arch` est posé.\n\n" <>
          signature

      gk_opts =
        ctx.forge_opts
        |> as_role(Fleet.Pilot.GatekeeperSeal.gatekeeper_role())
        |> Keyword.put(:dedup_signature, signature)
        |> Keyword.put(:dedup_any_author, true)

      _ = ctx.forge.post_comment(ctx.repo, issue_n, body, gk_opts)
      _ = ctx.forge.add_label(ctx.repo, issue_n, @awaits_arch_label, ctx.forge_opts)

      # `{:skipped, _}` = forme GÉRÉE par le poller (stage_process_pulls) → compté skipped, pas de crash.
      # L'ancien `{:escalated, _}` n'était dans AUCUNE clause du `case do_poll` → CaseClauseError à chaque tick
      # (vu live, PR#4 arduino-morse) : un retour de dispatch DOIT être {:ok|:skipped|:error}, jamais une 4ᵉ forme.
      {:skipped, {:merge_conflict_escalated, pr_number}}
    end
  end

  defp dispatch_pr_role(kind, pr_number, head, role, ctx) do
    with {:ok, {issue_n, _producer}} <- parse_feature_branch_or_skip(head),
         {:ok, profile} <- load_role_or_skip(ctx.loader, role) do
      do_dispatch_review(pr_number, issue_n, head, role, profile, kind, ctx)
    end
  end

  defp parse_feature_branch_or_skip(head) do
    case Fleet.Pilot.ForgeClient.parse_feature_branch(head) do
      {:ok, _} = ok -> ok
      :error -> {:skipped, :not_fleet_branch}
    end
  end

  defp load_role_or_skip(_loader, ""), do: {:skipped, :no_role}

  defp load_role_or_skip(loader, role) do
    case loader.load(role) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:skipped, :no_role}
    end
  end

  defp do_dispatch_review(pr_number, issue_n, head, role, profile, kind, ctx) do
    # #5.2 D3 — spawner/task_queue ne sont plus lus ici directement : ils transitent via `ctx` vers `spawn_stage`.
    %{
      repo: repo,
      forge: forge,
      resolver: resolver,
      forge_opts: forge_opts,
      opts: opts
    } = ctx

    # ②.1d — le pod review (juge) OU rework (producteur) clone la FEATURE-BRANCH (`head.ref`), PAS
    # `main` : le juge doit voir le DIFF du producteur (sinon il juge `main`, c.-à-d. rien de réel) ;
    # le rework reprend SON propre travail. Read-only sur le code via le workspace provisionné par le
    # système (barrière §4 préservée : zéro token forge au pod). `base_branch: head` → le pod CLONE et
    # part du tip de la feature-branch.
    #
    # F-PARALLEL-PR-CONFLICT — la RÉSOLUTION (rebase) part AUSSI de la feature (son travail à rebaser),
    # mais son livrable doit DESCENDRE de `main` (la cible du rebase), pas de l'ancien tip de feature
    # (réécrit par le rebase → la gate F-03 le rejetterait : `base_not_ancestor`, bug live PR#4). On
    # DÉCONFLE les deux rôles jadis portés par `base_sha` : `base_branch` = clone-base (feature, le pod
    # part de là, INCHANGÉ) ; `gate_base_branch` = "main" → le resolver pinne la base de GATE sur `main`.
    # judge/rework (forward, pas de réécriture) : pas de `gate_base_branch` → gate = clone-base, inchangé.
    review_opts =
      opts
      |> Keyword.put(:base_branch, head)
      |> maybe_gate_base_main(kind)

    # PROJET + ROUTE resolus AVANT toute ecriture forge (read-only) : un echec ne laisse pas de
    # verrou orphelin. La route (pipeline, stage) est lue sur l'ISSUE (le pipeline-state y reste).
    with {:ok, project} <- tag_err(resolver.(repo, review_opts), :project_resolution),
         {:ok, route} <- tag_err(route_for(forge, repo, issue_n, forge_opts), :route_resolution) do
      # BL-055 : id déterministe stable. Le REWORK (producteur) keye sur l'ISSUE → MÊME id que
      # dispatch_issue → retombe sur l'eng pipe vivant pour le RE-MANDATER (garde son contexte de
      # diagnostic across reworks). Le JUGE (one-shot) keye sur la PR → re-spawn frais à chaque review.
      pod_id =
        case kind do
          # #25 : repo-scopé. Rework + résolution-de-conflit keyent sur l'ISSUE → MÊME id que dispatch_issue
          # (reuse BL-055, l'eng pipe garde son contexte) ; juge keye sur la PR. Helper unique (Fleet.Pilot.PodId).
          k when k in [:rework, :resolve_conflict] ->
            Fleet.Pilot.PodId.for_issue(repo, issue_n, role)

          _ ->
            Fleet.Pilot.PodId.for_pr(repo, pr_number, role)
        end

      # :judge -> GateBrief desamorce (I-CBC) ; :rework -> brief de rework au PRODUCTEUR (corrige + push).
      mandate =
        review_mandate(kind, profile, role, forge, repo, issue_n, forge_opts, route, pr_number)

      spawn_opts =
        [mandate: mandate, pod_id: pod_id, rc_name: rc_name(repo, role)]
        |> maybe_put_project(project)
        |> maybe_put_route(route)
        |> maybe_put_repo_id(resolve_repo_id(forge, repo, forge_opts))

      # #5.2 D3 — spawn LEAF partagé avec dispatch_issue (verrou → pod → enqueue → wake + compensation).
      # Verrou keyé sur la PR (pr_number) ; ticket_id + enqueue keyés sur l'ISSUE (issue_n — le
      # pipeline-state y reste, et le rework retombe sur l'eng pipe `issue-N-producer`).
      log_ctx = "review pr=#{repo}##{pr_number} issue=##{issue_n}"
      spawn_stage(ctx, pod_id, role, profile, mandate, spawn_opts, pr_number, issue_n, log_ctx)
    else
      {:error, {phase, reason}} ->
        Logger.warning(
          "StageDispatcher: #{phase} review role=#{role} pr=#{repo}##{pr_number} → #{inspect(reason)} (skip, pas de verrou)"
        )

        {:error, {phase, reason}}
    end
  end

  # F-PARALLEL-PR-CONFLICT — DÉCONFLATION clone-base / gate-base. Une RÉSOLUTION (rebase) part de la
  # feature (clone-base, son travail) mais son livrable doit DESCENDRE de `main` (cible du rebase) → la
  # gate F-03 se base sur `main`, pas sur l'ancien tip de feature (réécrit par le rebase, donc pas
  # ancêtre). judge/rework (forward, pas de réécriture) : aucune divergence → gate = clone-base.
  defp maybe_gate_base_main(opts, :resolve_conflict),
    do: Keyword.put(opts, :gate_base_branch, "main")

  defp maybe_gate_base_main(opts, _kind), do: opts

  # ②.1d/②.1e — PROMOTE PR-state-driven (interim, sans branch-protection) : tous les juges ont
  # approuvé → le système SCELLE. Modèle identité ②.1e : comment de fin + merge signés GATEKEEPER
  # (gardien des PRs — « c'est dans son nom » ; token de rôle, `as_role`). Comment HONNÊTE (principe
  # traça user : on ne ment pas, on montre) : livré par l'eng, validé par les juges (APPROVED), mergé
  # par le système (branch-protection OFF en dev → LCARS agrège, pas Gitea — explicité). Le merge
  # `rebase` (LINÉAIRE, gère un `main` avancé sous une PR parallèle — multi-ticket, cf. merge_pr)
  # auto-close l'issue via `Closes #N` du body PR → close APRÈS merge, jamais avant. Pas de verrou
  # (poller mono-process) ; PR déjà mergée → 409 → la PR disparaît au tick suivant (idempotent).
  defp promote_pr(pr_number, head, ctx) do
    with {:ok, {issue_n, producer}} <- parse_feature_branch_or_skip(head) do
      # Sceau UNIQUE partagé avec `HopCompleter.promote` (F-arch-MCP) : commentaire gatekeeper + merge
      # signé gatekeeper. Plus de chemin de merge qui forke en token système (l'escalade signait `system`).
      gk_opts = as_role(ctx.forge_opts, Fleet.Pilot.GatekeeperSeal.gatekeeper_role())

      case Fleet.Pilot.GatekeeperSeal.seal_and_merge(
             ctx.forge,
             ctx.repo,
             pr_number,
             issue_n,
             producer,
             gk_opts
           ) do
        :ok ->
          # BL-055 die-on-promote : le lot est SCELLÉ (mergé) → l'eng pipe `issue-N-producer` (long-lived,
          # qui gardait son contexte across reworks) a fini sa vie → kill best-effort (no-op s'il est déjà
          # mort). Sans ça il lingère idle pour toujours = leak terminal du chantier eng-reuse.
          # #25 : MÊME helper repo-scopé que le spawn/rework → le kill cible bien le pod existant.
          _ = safe_kill(ctx.spawner, Fleet.Pilot.PodId.for_issue(ctx.repo, issue_n, producer))

          Logger.info(
            "StageDispatcher: PROMOTE pr=#{ctx.repo}##{pr_number} issue=##{issue_n} " <>
              "(juges OK → merge rebase, scellé gatekeeper, close via Closes ##{issue_n} ; eng tué)"
          )

          {:ok, {:merged, pr_number}}

        {:error, _} = err ->
          err
      end
    end
  end

  # `promote_comment` + le rôle gatekeeper + le merge sont désormais dans `Fleet.Pilot.GatekeeperSeal`
  # (sceau UNIQUE partagé avec `HopCompleter.promote`, F-arch-MCP — fin du fork de signature de merge).

  # ②.1e — injecte le token du compte de RÔLE dans les forge_opts → le SYSTÈME poste/merge EN SON NOM
  # (avatar/traça honnête, même mécanique que `create_ticket`/arch et `HopCompleter`). `nil` (token
  # absent/illisible/vide) → forge_opts inchangé → fallback token système ; `RoleToken.token/1` émet
  # un `Logger.warning` sur ce dégradé, il est donc OBSERVABLE ici. Barrière §4 :
  # le système poste avec le token de rôle, jamais le pod (forge-aveugle).
  defp as_role(forge_opts, role) when is_binary(role) and role != "" do
    case Fleet.Credentials.RoleToken.token(role) do
      t when is_binary(t) -> Keyword.put(forge_opts, :token, t)
      _ -> forge_opts
    end
  end

  defp as_role(forge_opts, _role), do: forge_opts

  # #chantier pod-seed : nom RC Desktop = `<projet>_<role>` (projet = segment final du repo, ex.
  # `fleet/poc-8` → `poc-8`). Label EXACT (claude_launch → `--remote-control "<nom>"`, zéro suffixe
  # auto). Distinct du pod_id (clé technique repo-scopée) ; ici c'est le label humain-lisible Desktop.
  defp rc_name(repo, role), do: "#{project_name(repo)}_#{role}"

  # #chantier monde-propre : nom de projet path/name-safe (charset [A-Za-z0-9-], zéro espace/`/`/`_`).
  # Segment final du repo, sanitizé. C'est LA source du `<project>` partout en aval (nom RC Desktop,
  # SANDBOX_HOME `/home/<project>`, seed-store, branche) via `rc_name` → un seul point de vérité, propre.
  # Pas de `_` (séparateur de rc_name `<project>_<role>` → garderait l'ambiguïté).
  defp project_name(repo),
    do: repo |> String.split("/") |> List.last() |> String.replace(~r/[^A-Za-z0-9-]/, "-")

  # #chantier monde-propre : slug parlant du titre du ticket pour la branche LOCALE (`feature/<slug>`).
  # Sanitizé + tronqué ; vide → `work`. Aucune fuite de pod_id/human.
  defp feature_slug(issue) do
    (issue["title"] || "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "work"
      s -> s
    end
  end

  defp maybe_put_project(spawn_opts, nil), do: spawn_opts
  defp maybe_put_project(spawn_opts, project), do: Keyword.put(spawn_opts, :project, project)

  defp maybe_put_route(spawn_opts, nil), do: spawn_opts

  defp maybe_put_route(spawn_opts, {pipeline, stage}),
    do: spawn_opts |> Keyword.put(:pipeline, pipeline) |> Keyword.put(:stage, stage)

  # BL-055 (M5) : `repo_id` = id forge du projet → session_id déterministe des rôles project-bound
  # (eng, juges) via `Fleet.Spawner.SessionId` (segment `<REPO4>` DÉCIMAL). Best-effort : forge sans
  # `repo_id` (stub) / forge down / id absent → `nil` → pas de `repo_id` posé → le spawner retombe sur un
  # UUID random (zéro collision). `rem(id, 10000)` : `<REPO4>` = 4 chiffres décimaux → DETTE assumée, le
  # repo 10000 collisionne le repo 0 (on ne rouvrira pas le vieux ; cf. SessionId moduledoc).
  defp maybe_put_repo_id(spawn_opts, nil), do: spawn_opts
  defp maybe_put_repo_id(spawn_opts, repo_id), do: Keyword.put(spawn_opts, :repo_id, repo_id)

  defp resolve_repo_id(forge, repo, forge_opts) do
    if function_exported?(forge, :repo_id, 2) do
      case forge.repo_id(repo, forge_opts) do
        {:ok, id} when is_integer(id) and id >= 0 -> rem(id, 10000)
        _ -> nil
      end
    else
      nil
    end
  end

  # Mandat d'un dispatch PR (Corr.3 4-C) : :judge -> GateBrief desamorce (via build_mandate, le pod
  # juge l'issue) ; :rework -> brief de rework au PRODUCTEUR (corrige selon la review, re-pousse).
  # #8.B/#8.E : chemin PR-juge — pas de stage carte ici (juges PR-driven) → `stage_spec = %{}` :
  # build_mandate retombe sur le `mandate_kind` du profil (judge pour qualifier/reviewer) ET sur le
  # `judge_target` par défaut (deliverable) → build_judge_mandate (juge le livrable/PR). Inchangé.
  defp review_mandate(:judge, profile, role, forge, repo, issue_n, forge_opts, route, _pr),
    do: build_mandate(profile, role, forge, repo, issue_n, %{}, forge_opts, route, %{})

  defp review_mandate(:rework, _profile, role, forge, repo, _issue_n, forge_opts, route, pr),
    do: rework_mandate(role, forge, repo, pr, forge_opts, route)

  defp review_mandate(
         :resolve_conflict,
         _profile,
         role,
         forge,
         repo,
         _issue_n,
         forge_opts,
         route,
         pr
       ),
       do: resolve_conflict_mandate(role, forge, repo, pr, forge_opts, route)

  # Brief de rework (4-C-iv) : le PRODUCTEUR (engineer) reprend sur une PR REQUEST_CHANGES.
  # PORTE LA MÊME instruction git-native que `build_worker_mandate` (sinon `:no_deliverable_commit` : le
  # rework « re-pousse » mais le pod est FORGE-AVEUGLE et sans l'ordre de COMMITTER il ne livre rien —
  # bug prouvé live e2e #1, F090 jumeau). Le pod corrige + commite EN LOCAL ; le SYSTÈME pousse (barrière
  # §4). Trailer obligatoire (gate F-01).
  #
  # FAMINE D'INFO, moitié rework (fix #1, prouvé live morse) : sans le BODY des reviews REQUEST_CHANGES,
  # « corrige selon la review » est creux — le pod forge-aveugle ne voit PAS la review → il devine à
  # l'aveugle (l'eng morse a refusé de deviner → `blocked_dep` → wedge). On lit le feedback sur la forge
  # (le runtime, pas le pod : barrière §4 préservée) et on l'injecte. Si la lecture échoue / aucun body,
  # on retombe sur l'instruction générique (le pod a quand même la PR clonée + son code).
  defp rework_mandate(role, forge, repo, pr, forge_opts, _route) do
    [
      "REWORK — une review REQUEST_CHANGES a été déposée sur la PR ##{pr}. Corrige ton code selon le " <>
        "feedback de la review ci-dessous.",
      render_rework_feedback(forge, repo, pr, forge_opts),
      "**Livraison (git-native)** : applique tes corrections dans ton workspace, puis `git add` + `git commit`. " <>
        "Le SYSTÈME pousse ton commit (forge-aveugle, toi tu ne push pas). `submit_result` clôt la tâche : le " <>
        "LIVRABLE = ton COMMIT (ne RE-mets PAS les fichiers dans le payload). Le payload porte ta voix ↓.",
      eng_voice_instruction(:rework),
      Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # Brief de RÉSOLUTION DE CONFLIT (F-PARALLEL-PR-CONFLICT) : la PR est APPROUVÉE mais `main` a avancé (un
  # autre ticket parallèle a fusionné) → conflit. Le PRODUCTEUR (git_native, il a écrit le contenu) RÉCONCILIE :
  # rebase sur `main` + résolution en gardant TOUT (le sien + main). Pas un re-code. Le système pousse (§4) ;
  # le push rebasé invalide les vieilles reviews (head_sha) → les juges re-valident le fusionné, gatekeeper scelle.
  defp resolve_conflict_mandate(role, _forge, _repo, pr, _forge_opts, _route) do
    [
      "RÉSOLUTION DE CONFLIT — ta PR ##{pr} a été APPROUVÉE, mais `main` a avancé depuis (un autre ticket " <>
        "parallèle a été fusionné) et ta branche **conflicte** avec `main`. On ne te demande PAS de re-coder : " <>
        "juste de RÉCONCILIER les deux versions.",
      "**Procédure (git-native)** : dans ton workspace, `git fetch origin` puis `git rebase origin/main`. Pour " <>
        "CHAQUE fichier en conflit, résous en **gardant TOUT le contenu utile** — le tien ET celui arrivé sur " <>
        "`main` (ex. un README partagé : garde les DEUX sections, ne supprime rien). `git add` les fichiers " <>
        "résolus puis `git rebase --continue` (et `git commit` si besoin). Le SYSTÈME pousse (forge-aveugle, tu " <>
        "ne push pas). `submit_result` clôt : le LIVRABLE = tes COMMIT(s) rebasés (ne RE-mets PAS les fichiers " <>
        "dans le payload). Le payload porte ta voix ↓.",
      eng_voice_instruction(:rework),
      Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # VOIX DE L'ENG (info SORTANTE, jumeau de la famine d'info entrante) : le `summary` rendu dans
  # `submit_result` est POSTÉ sur la PR par le système (forge-aveugle, `as_role` engineer) → l'eng
  # a enfin une voix pour l'humain. Sans ça il est muet sur la forge (le diagnostic morse en or n'a
  # jamais été vu). [[feedback_verbose_descriptive_traceable]]
  defp eng_voice_instruction(:build) do
    "**Ta voix — le `payload` de `submit_result` DOIT contenir un champ `summary`** " <>
      "(ex. `submit_result` avec `payload = {\"summary\": \"Implémenté X ; choisi Y parce que Z\"}`). Le " <>
      "`summary` (markdown COURT) = ce que tu as réalisé + décisions/hypothèses notables. ⚠ ce N'EST PAS du " <>
      "contenu de fichier (ça, c'est ton COMMIT) — c'est ta NARRATION. Le SYSTÈME la poste en commentaire sur " <>
      "la PR : c'est ta SEULE voix pour l'humain qui review. **Si tu es BLOQUÉ** (dépendance/info manquante) " <>
      "et ne peux PAS livrer : NE devine PAS — ajoute `\"blocked\": true` au payload (à côté de `summary` = le " <>
      "motif PRÉCIS, ce qui te manque). Le système ESCALADE à l'humain (aucun commit attendu de toi), jamais un " <>
      "wedge silencieux. Ex. `payload = {\"blocked\": true, \"summary\": \"Manque la spec du protocole X — ...\"}`."
  end

  defp eng_voice_instruction(:rework) do
    "**Ta voix — le `payload` de `submit_result` DOIT contenir un champ `summary`** " <>
      "(ex. `payload = {\"summary\": \"Corrigé le point A en faisant B ; pour le point C, ...\"}`). Le " <>
      "`summary` = COMMENT tu as répondu à CHAQUE point de la review (ce que tu as corrigé). C'est ta " <>
      "NARRATION (pas le code — déjà committé). Le SYSTÈME le poste sur la PR : ta réponse traçable au reviewer."
  end

  # Rend le feedback des reviews REQUEST_CHANGES (body du verdict de chaque juge) en bloc actionnable.
  # `""` si rien (lecture KO ou aucun body) → le brief retombe sur l'instruction générique (Enum.reject).
  defp render_rework_feedback(forge, repo, pr, forge_opts) do
    case forge.change_request_feedback(repo, pr, forge_opts) do
      {:ok, [_ | _] = feedbacks} ->
        sections =
          Enum.map_join(feedbacks, "\n\n", fn fb ->
            "### Review de `#{fb["login"]}`\n#{fb["body"]}"
          end)

        "## Feedback de review à traiter (REQUEST_CHANGES)\n\n#{sections}"

      _ ->
        ""
    end
  end

  # F077 : la forme du mandat est une propriété du rôle (cap-profile `mandate_kind`), PAS un nom
  # magique en ring2. `judge` → GateBrief désamorcé ; tout le reste (`worker`, défaut) → corps d'issue.
  defp build_mandate(
         profile,
         role,
         forge,
         repo,
         number,
         issue,
         forge_opts,
         route,
         stage_spec
       ) do
    # #8.B : le `mandate_kind` du STAGE (carte) PRIME sur celui du profil (override per-stage) — réutilise
    # un profil worker (consultant) en JUGE sans profil-doublon. Absent → défaut profil ("worker").
    kind = Map.get(stage_spec, "mandate_kind") || Fleet.CapProfile.mandate_kind(profile)

    case {kind, Map.get(stage_spec, "judge_target")} do
      # #8.E : juge de MANDAT (judge_target:mandate) → juge le ticket.body (exécutable ?), PAS un livrable
      # (pas de code en amont). judge_target absent/deliverable → juge un livrable (PR), brief inchangé.
      {"judge", "mandate"} ->
        build_mandate_review_mandate(role, issue, forge, repo, number, forge_opts, route)

      {"judge", _deliverable} ->
        build_judge_mandate(role, forge, repo, number, forge_opts, route)

      _worker ->
        build_worker_mandate(role, issue)
    end
  end

  # Mandat producteur = le brief de l'issue + l'instruction de LIVRAISON git-native. Sans elle (le rail
  # forge l'avait perdue vs le rail RAM — régression F090), le pod « submit les contenus » au lieu de
  # COMMITTER → la publish git_native ne trouve aucun commit (`:no_deliverable_commit`, prouvé live #3).
  # Le pod commite en LOCAL ; le SYSTÈME pousse + ouvre la PR (forge-aveugle, barrière §4). Le trailer
  # est obligatoire (gate F-01 au push, source unique `ForgeIdentity.coauthor_instruction`).
  defp build_worker_mandate(role, issue) do
    [
      issue["body"] || "",
      "---",
      "**Livraison (git-native)** : réalise le travail dans ton workspace, puis `git add` + `git commit`. " <>
        "Le SYSTÈME pousse ton commit et ouvre la PR — toi tu ne push pas (forge-aveugle). `submit_result` " <>
        "clôt la tâche : le LIVRABLE = ton COMMIT (ne RE-mets PAS le code/les fichiers dans le payload, ils " <>
        "sont déjà committés). Le payload, lui, N'EST PAS vide : il porte ta voix ↓.",
      eng_voice_instruction(:build),
      Fleet.Credentials.ForgeIdentity.coauthor_instruction(role)
    ]
    |> Enum.join("\n\n")
  end

  # A2.3b item 5 (option B, DN gatekeeper-forge-encoding-v2 §5) : un pod **juge** doit savoir QUOI
  # juger ET comment rendre son verdict. On réutilise le brief canonique `Fleet.Pipeline.GateBrief`
  # (contexte + livrable + question + **contrat `gate-decision-v1.json` + options canon**) — le même
  # que le modèle RAM. Le `result_K` à juger est lu du comment du hop précédent (gravé par
  # HopCompleter, N-04) ; le pod reste forge-aveugle (le runtime lit le comment, option B, pas de
  # clone F-08).
  defp build_judge_mandate(role, forge, repo, number, forge_opts, route) do
    predecessor =
      case forge.get_predecessor_result(repo, number, forge_opts) do
        {:ok, result} when is_map(result) and map_size(result) > 0 -> result
        _ -> nil
      end

    # GIT-NATIVE (predecessor vide, live #8) : le livrable N'EST PAS un payload — c'est le CODE de la
    # branche. Le juge clone la feature-branch + a `Bash(git diff/log/show)` → on le POINTE sur son
    # workspace au lieu de lui donner `{}` (sur quoi il fail-closait `halt_wait_input`). Sinon il juge
    # du vide → rework infini (le Reviewer ne peut JAMAIS dire `continue` sur `{}`).
    outputs =
      predecessor ||
        %{
          "livrable" =>
            "git-native — le code à juger est checkout dans TON workspace. Le clone est mono-branche : " <>
              "la base est `origin/main` (le ref local `main` N'EXISTE PAS). Le diff de la PR = " <>
              "`git diff origin/main...HEAD` (trois points — point de divergence auto). `git log origin/main..HEAD` " <>
              "pour les commits, `git show <sha>` pour le détail. Juge ces changements contre le critère ci-dessous."
        }

    # CRITÈRE de réussite = le body de l'issue (le mandat). Passé via `:request` → GateBrief le rend
    # DÉSAMORCÉ (contexte, pas instruction exécutable, I-CBC) → le juge sait CONTRE QUOI juger.
    request =
      case forge.get_issue(repo, number, forge_opts) do
        {:ok, issue} -> Map.get(issue, "body")
        _ -> nil
      end

    {pipeline, stage} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    # I-CBC (bug PASSE-9, prouvé live #11 ET #12) : le mandat du juge ne contient AUCUNE instruction
    # exécutable. Le `request` (body de l'issue = critère) est rendu par GateBrief DÉSAMORCÉ (blockquote
    # « CONTEXTE — déjà traité, NE PAS exécuter » + bannière « JUGER, PAS PRODUIRE »). Le warning #11/#12
    # visait un juge **base-worker** (profile noop, gatekeeper) qui RE-exécute le build même quoté : ce
    # juge-là reçoit son brief par `dispatch_gatekeeper` (hop_consumer) qui NE passe PAS `request` — il
    # n'est pas affecté ici. `build_judge_mandate` ne sert que les juges À PERSONA (qualifier/reviewer,
    # `subagent_template` spec-reviewer/code-quality-reviewer) — le cas que le warning déclarait SÛR
    # (« si un jour le juge a une vraie persona, GateBrief sait rendre `request` désamorcé »). Preuve
    # live morse : ces juges fail-closent `halt_wait_input` sur livrable vide, ils ne RE-buildent pas.
    # Sans le critère (`request`) ET le livrable (diff via `outputs`), le juge jugeait du `{}` → rework
    # infini (le Reviewer ne peut JAMAIS `continue` sur du vide) — c'est la famine d'info, fix #1.
    Fleet.Pipeline.GateBrief.build(%{
      stage: stage,
      pipeline_id: pipeline,
      gate: nil,
      outputs: outputs,
      request: request
    })
  end

  # #8.E — mandat d'un juge de MANDAT (mandate-review, judge_target:mandate). Le consultant juge le MANDAT
  # (ticket.body rédigé par l'arch) AVANT que l'engineer ne parte : exécutable sans nouvelle question ? On
  # réutilise le MÊME GateBrief (contrat gate-decision-v1 + options canon) que les autres juges — seul le
  # `subject: :mandate` recadre le « truc à juger ». Le MANDAT va dans `outputs` (le truc À JUGER ; ≠
  # build_judge_mandate où outputs = le livrable/code) ; pas de `request` (le critère d'exécutabilité est
  # porté par le cadrage :mandate). Le juge est PRÉ-PR (aucun clone, aucun livrable) → cohérent N0.
  defp build_mandate_review_mandate(role, issue, forge, repo, number, forge_opts, route) do
    # F-S2-1 : le mandat = body de l'ISSUE, DÉJÀ en main (le poller a listé l'issue ; mandate-review est
    # toujours issue-path). On l'utilise → pas de `get_issue` redondant. Fallback fetch si body absent (robustesse).
    mandat = issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts)

    {pipeline, stage} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    Fleet.Pipeline.GateBrief.build(%{
      stage: stage,
      pipeline_id: pipeline,
      gate: nil,
      subject: :mandate,
      outputs: %{"mandat" => mandat}
    })
  end

  # F-S2-1 : body de l'issue DÉJÀ listée par le poller → utilisé direct ; fetch SEULEMENT en fallback
  # (body absent/vide — défensif ; mandate-review est toujours issue-path, l'issue est en main).
  defp issue_body_in_hand_or_fetch(issue, forge, repo, number, forge_opts) do
    case Map.get(issue, "body") do
      body when is_binary(body) and body != "" ->
        body

      _ ->
        case forge.get_issue(repo, number, forge_opts) do
          {:ok, fetched} -> Map.get(fetched, "body") || ""
          _ -> ""
        end
    end
  end

  # Tag l'erreur d'une étape de résolution (préserve {:project_resolution, _} attendu).
  defp tag_err({:ok, _} = ok, _tag), do: ok
  defp tag_err({:error, reason}, tag), do: {:error, {tag, reason}}

  # #8 (carte-driven role) : dérive `{role, profile, stage_spec}` de la POSITION carte (route gravée) +
  # load du profil. route nil = anomalie → fail-loud (#5.2 D2 — plus de fallback producteur). Carte/stage/
  # profil non résolus = misconfig → `{:error, _}` (fail-loud).
  # `prefetched_carte` (F-S1-1) : carte déjà chargée par le poller (classification du bail) → on évite un
  # 2ᵉ load ; `nil` (tests, autres callers) → chargement via `carte_loader` (fallback).
  @spec carte_role(
          {String.t(), String.t()} | nil,
          (String.t() -> {:ok, Fleet.CapProfile.t()} | {:error, term()}),
          (String.t() -> map()),
          map() | nil
        ) :: {:ok, {String.t(), Fleet.CapProfile.t(), map()}} | {:error, term()}
  # #5.2 D2 — route nil = ANOMALIE : le poller onboarde tout routeless AVANT dispatch (ensure_carte_or_onboard)
  # → si on arrive ici sans route, fail-loud, JAMAIS un fallback eng silencieux. Le rôle vient TOUJOURS de la
  # position carte (route gravée).
  defp carte_role(nil, _load_role, _carte_loader, _prefetched_carte), do: {:error, :unrouted}

  defp carte_role({pipeline, stage}, load_role, carte_loader, prefetched_carte) do
    with {:ok, carte} <- carte_or_load(prefetched_carte, pipeline, carte_loader),
         {:ok, role} <- carte_stage_role(carte, pipeline, stage),
         {:ok, profile} <- load_role.(role) do
      # #8.B/#8.E : on remonte le STAGE_SPEC entier (extensible) plutôt qu'un champ isolé. build_mandate y
      # lit `mandate_kind` (#8.B — override per-stage : consultant worker → juge sans profil-doublon) ET
      # `judge_target` (#8.E — juge le MANDAT vs un livrable). route=nil (producteur A1) → stage_spec vide.
      stage_spec = get_in(carte, ["stages", stage]) || %{}
      {:ok, {role, profile, stage_spec}}
    end
  end

  # F-S1-1 : carte pré-chargée (poller) → réutilisée ; sinon chargée via le seam.
  defp carte_or_load(nil, pipeline, carte_loader), do: load_carte(pipeline, carte_loader)
  defp carte_or_load(carte, _pipeline, _carte_loader), do: {:ok, carte}

  # F-S1-1 : route pré-lue par le poller (classification) → réutilisée ici ; absente → lecture forge.
  defp resolve_route(opts, forge, repo, number, forge_opts) do
    case Keyword.fetch(opts, :prefetched_route) do
      {:ok, route} -> {:ok, route}
      :error -> route_for(forge, repo, number, forge_opts)
    end
  end

  # #5.2 D2 — onboarding système. Route présente → passthrough `{:ok, route}`. Route nil (issue routeless :
  # create_ticket ne grave plus la carte ; ou ticket humain brut) → grave la carte par défaut (mandate-gate)
  # = elle ENTRE dans le gate → `{:onboarded, stage}` (dispatch_issue défère : skip ce tick, le suivant la
  # voit routée). Route postée par le SYSTÈME (forge token système). Échec → `{:error, {:onboard, _}}`.
  defp ensure_carte_or_onboard(_forge, _repo, _number, route, _carte_loader, _forge_opts)
       when not is_nil(route),
       do: {:ok, route}

  defp ensure_carte_or_onboard(forge, repo, number, nil, carte_loader, forge_opts) do
    carte_name = default_carte()

    with {:ok, carte} <- load_carte(carte_name, carte_loader),
         {:ok, {stage, _role}} <- Fleet.Pilot.CarteNav.first_stage(carte),
         {:ok, _} <- forge.post_route(repo, number, carte_name, stage, forge_opts) do
      {:onboarded, stage}
    else
      err -> {:error, {:onboard, err}}
    end
  end

  # Carte par défaut de l'onboarding (toute issue assignée routeless y entre ; défaut mandate-gate : le
  # consultant review le mandat AVANT l'eng). Data-catalogue, pas un nom magique en dur.
  defp default_carte, do: Application.get_env(:fleet_pilot, :delegation_carte, "mandate-gate")

  defp load_carte(pipeline, carte_loader) do
    {:ok, carte_loader.(pipeline)}
  rescue
    e -> {:error, {:carte_load_failed, pipeline, Exception.message(e)}}
  end

  defp carte_stage_role(carte, pipeline, stage) do
    case Fleet.Pilot.CarteNav.stage_role(carte, stage) do
      {:ok, role} when is_binary(role) -> {:ok, role}
      _ -> {:error, {:carte_stage_unknown, pipeline, stage}}
    end
  end

  # Lit la position carte (pipeline, stage) gravée sur la forge (A2.1). `:none` (hors-carte /
  # 1-stage) → `{:ok, nil}` (comportement A1). Erreur HTTP → propagée (skip sans verrou).
  defp route_for(forge, repo, number, forge_opts) do
    case forge.get_route(repo, number, forge_opts) do
      {:ok, {_p, _s} = route} -> {:ok, route}
      :none -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # Enqueue le mandat dans le broker `Fleet.TaskQueue` ciblé pod_id — le claude REPL le pull via
  # `mcp__fleet__get_task` → `PodTools.get_task` → `TaskQueue.get_for_pod` (PAS un Read fichier).
  # MÊME mécanisme que `StageRunner.push_task_for_pod` (DN §8 « réutilise StageRunner ») : sans cet
  # enqueue, `TaskQueue.pod_status(pod_id) == nil` → le pod se croit bootstrap (rien à puller) → idle.
  # Le `brief` = le MANDAT role-aware déjà construit (build_mandate) : GateBrief I-CBC pour le
  # gatekeeper, corps de l'issue pour un worker. F078 : c'était `issue["body"]` brut → le juge
  # pullait le mandat BUILD exécutable (PASSE-9). `metadata.issue` corrèle au ticket.
  defp enqueue_mandate(task_queue, pod_id, role, number, mandate) do
    attrs = %{
      ticket_id: Fleet.Pilot.TicketId.compose(number),
      role: role,
      brief: mandate,
      metadata: %{"issue" => number}
    }

    case task_queue.enqueue(pod_id, attrs) do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp safe_wake(spawner, pod_id) do
    if function_exported?(spawner, :wake_pod, 1), do: spawner.wake_pod(pod_id), else: :ok
  rescue
    _ -> :ok
  end

  # F181 — compensation best-effort : tue le pod (s'il a spawné) avant de retirer le verrou.
  # No-op silencieux si le spawner n'expose pas `kill_pod/1` ou si le pod n'existe pas.
  defp safe_kill(spawner, pod_id) do
    if function_exported?(spawner, :kill_pod, 1), do: spawner.kill_pod(pod_id), else: :ok
  rescue
    _ -> :ok
  end

  # BL-055 — dispatch idempotent. Un pod déjà VIVANT (id déterministe stable) = l'eng pipe long-lived
  # → on le RE-MANDATE (enqueue + wake, garde son contexte), pas de re-spawn (plus de leak/orphelin).
  # `pod_alive?` défaute à `false` si le spawner n'expose pas `pod_info/1` (stubs de test) → chemin
  # spawn inchangé.
  defp pod_alive?(spawner, pod_id) do
    function_exported?(spawner, :pod_info, 1) and match?({:ok, _}, spawner.pod_info(pod_id))
  rescue
    _ -> false
  end

  defp maybe_spawn(_spawner, true = _alive?, _profile, _ticket_id, _spawn_opts),
    do: {:ok, :remandated}

  defp maybe_spawn(spawner, false = _alive?, profile, ticket_id, spawn_opts) do
    case spawner.spawn_pod(profile, ticket_id, spawn_opts) do
      {:ok, _pid} -> {:ok, :spawned}
      {:error, _} = err -> err
    end
  end

  defp disposition(true = _alive_before?), do: "re-mandated (pod vivant, contexte gardé)"
  defp disposition(false = _alive_before?), do: "spawned"

  # #5.2 D3 — LEAF de spawn partagé par dispatch_issue (producteur) ET do_dispatch_review (juge/rework).
  # ORDRE CANONIQUE (DN §6) : label-verrou `lcars-in-flight` AVANT pod (sinon double-spawn) → pod
  # (`maybe_spawn` : RE-MANDATE si vivant, BL-055) → enqueue du mandat (que le pod pull via get_task) →
  # wake+recovery (#5.2). Échec POST-verrou (F181) → compensation : retrait du verrou (+ kill SI frais spawn,
  # JAMAIS un re-mandate vivant). `lock_target` = l'objet verrouillé (issue number | PR number) ;
  # `ticket_number` = le ticket (issue) pour le `ticket_id` ET l'enqueue ; `log_ctx` = contexte de log caller.
  defp spawn_stage(
         ctx,
         pod_id,
         role,
         profile,
         mandate,
         spawn_opts,
         lock_target,
         ticket_number,
         log_ctx
       ) do
    %{forge: forge, spawner: spawner, task_queue: task_queue, repo: repo, forge_opts: forge_opts} =
      ctx

    # MA-17 — seam d'injection du recovery de wake (défaut = la vraie fn). Même pattern que les seams
    # forge/spawner/task_queue : permet de tester le tally honnête sans hit IncidentRegistry/forge réels.
    wake_recovery = Map.get(ctx, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3)

    ticket_id = Fleet.Pilot.TicketId.compose(ticket_number)
    alive_before? = pod_alive?(spawner, pod_id)

    with {:ok, _} <- forge.add_label(repo, lock_target, @in_flight_label, forge_opts),
         {:ok, _} <- maybe_spawn(spawner, alive_before?, profile, ticket_id, spawn_opts),
         :ok <- enqueue_mandate(task_queue, pod_id, role, ticket_number, mandate) do
      # MA-17 — le retour de `WakeRecovery.wake` est LOAD-BEARING : `{:error, {:escalated, _}}`
      # (pod injoignable, escaladé à starfleet) ou `{:error, _}` (re-wake KO) signifie que le pod n'est
      # PAS réveillé. AVANT : `_ = wake(...)` jetait ce retour → `spawn_stage` rendait toujours
      # `{:ok, {:spawned}}` → le poller comptait `dispatched +1 / errors 0` MENTEUR (pod jamais réveillé,
      # mais tally clean). On le MATCHE maintenant : le verrou + le mandat + le pod RESTENT en place (le
      # mandat est enqueué, l'escalade système existe → pas un cul-de-sac, re-wake au prochain tick), mais
      # le dispatch n'est PAS un succès silencieux — il remonte `{:error, {:wake_unreached, …}}` → le poller
      # le compte en `errors` (tally honnête + err_streak/telemetry reflètent l'injoignabilité réelle).
      case wake_recovery.(
             pod_id,
             fn -> maybe_spawn(spawner, false, profile, ticket_id, spawn_opts) end,
             wake_fun: fn p -> safe_wake(spawner, p) end
           ) do
        :ok ->
          Logger.info(
            "StageDispatcher: #{disposition(alive_before?)} role=#{role} pod=#{pod_id} #{log_ctx}"
          )

          {:ok, {:spawned, pod_id, role}}

        {:error, reason} ->
          # PAS de compensation : verrou conservé (le pod est dispatché, l'objet EST in-flight),
          # mandat conservé, pod conservé. Seul le réveil a échoué → tally honnête + re-wake au tick suivant
          # (idempotent : alive_before? sera vrai, maybe_spawn no-op, re-wake retenté).
          Logger.warning(
            "StageDispatcher: #{disposition(alive_before?)} role=#{role} pod=#{pod_id} #{log_ctx} " <>
              "MAIS wake INJOIGNABLE → #{inspect(reason)} (verrou+mandat conservés, re-wake au prochain tick ; " <>
              "tally = error, pas dispatched silencieux)"
          )

          {:error, {:wake_unreached, pod_id, role, reason}}
      end
    else
      {:error, _} = err ->
        # F181 : une étape POST-verrou a échoué → compensation (retrait du verrou, sinon stuck à jamais).
        # Kill SEULEMENT si frais spawn (un re-mandate ne tue JAMAIS l'eng vivant + son contexte, BL-055).
        if not alive_before?, do: safe_kill(spawner, pod_id)
        _ = forge.remove_label(repo, lock_target, @in_flight_label, forge_opts)

        Logger.warning(
          "StageDispatcher: dispatch role=#{role} pod=#{pod_id} #{log_ctx} → #{inspect(err)} " <>
            "(verrou retiré#{if(not alive_before?, do: ", pod tué", else: "")} — re-dispatch au prochain tick)"
        )

        err
    end
  end

  # ============================================================
  # Internals
  # ============================================================

  # ============================================================
  # Résolution projet (base_sha pinné hors-pod, F-03 R1)
  # ============================================================

  # Construit `%{repo_path, base_branch, base_sha}` pour le repo du ticket.
  # `base_url` ← `:forge_opts[:base_url]` ou config app ; `base_branch` ← `:base_branch`
  # (défaut "main"). Pas de forge configurée → `{:ok, nil}` (pod sans repo, ex. tests
  # locaux). L'auth de clone/ls-remote est portée par le runtime (`Fleet.Credentials.ForgeAuth.
  # git_env`, token via env), jamais par le pod (barrière §4).
  @spec default_project_resolver(String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def default_project_resolver(repo, opts) do
    forge_opts = Keyword.get(opts, :forge_opts, [])
    base_branch = Keyword.get(opts, :base_branch, "main")

    # F-PARALLEL-PR-CONFLICT — DÉCONFLATION clone-base / gate-base. `base_sha` portait JADIS deux
    # concerns confondus : (1) le POINT DE DÉPART du clone (`pin_base_sha` reset HEAD dessus) et (2) la
    # base de la GATE F-03 (HEAD doit en DESCENDRE). Forward (build/rework) : ils coïncident. RÉSOLUTION
    # par rebase : ils DIVERGENT — le pod part de la feature (son travail) mais doit descendre de `main`.
    # `:gate_base_branch` (posé par le dispatch resolve) pinne la base de gate séparément ; absent → la
    # gate retombe sur la clone-base (`base_sha`), comportement forward INCHANGÉ.
    gate_base_branch = Keyword.get(opts, :gate_base_branch)

    case forge_base_url(forge_opts) do
      nil ->
        {:ok, nil}

      base_url ->
        repo_url = "#{String.trim_trailing(base_url, "/")}/#{repo}.git"

        with {:ok, sha} <- ls_remote_sha(repo_url, base_branch),
             {:ok, gate_sha} <- resolve_gate_base_sha(repo_url, gate_base_branch, sha) do
          # F-037 : `"repo"` (full_name "owner/name") embarqué dans le projet → il voyage jusqu'au pod
          # puis ressort dans `pod.completed` (`pod_completed_payload`) → le HopConsumer sait sur QUEL
          # repo agir (multi-projet), sans le re-dériver. `repo_path` = l'URL de push (remote per-hop).
          {:ok,
           %{
             "repo" => repo,
             "repo_path" => repo_url,
             "base_branch" => base_branch,
             "base_sha" => sha,
             # gate_base_sha = base de la GATE F-03 (≠ clone-base pour une résolution rebase, cf. supra).
             "gate_base_sha" => gate_sha
           }}
        end
    end
  end

  # Base de la GATE F-03. Défaut (forward) : = clone-base (`base_sha`) → la garde exige que HEAD descende
  # de là où le pod a cloné. Un dispatch resolve passe `:gate_base_branch` ("main") → on pinne le tip de
  # CETTE branche (la cible du rebase) : la garde exige alors que HEAD descende de `main`, pas de l'ancien
  # tip de feature (réécrit par le rebase → il ne serait plus ancêtre, d'où le `base_not_ancestor` live).
  defp resolve_gate_base_sha(_repo_url, nil, clone_base_sha), do: {:ok, clone_base_sha}

  defp resolve_gate_base_sha(repo_url, branch, _clone_base_sha) when is_binary(branch),
    do: ls_remote_sha(repo_url, branch)

  defp forge_base_url(forge_opts) do
    Keyword.get(forge_opts, :base_url) ||
      get_in(Application.get_env(:fleet_pilot, :forge, []), [:base_url])
  end

  # `git ls-remote <repo_url> <branch>` borné + auth runtime → SHA du tip (hors-pod).
  # Symétrique de `Fleet.Pipeline.Executor.ls_remote_sha` (même rôle F-03 R1).
  defp ls_remote_sha(repo_url, branch) do
    # F087/F095 : token forge via env (hors argv/cmdline) — source unique Fleet.Credentials.ForgeAuth.
    git_env = Fleet.Credentials.ForgeAuth.git_env()

    task =
      Task.async(fn ->
        System.cmd("git", ["ls-remote", repo_url, branch], stderr_to_stdout: true, env: git_env)
      end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        case out |> String.split("\n", trim: true) |> List.first() do
          nil -> {:error, :no_ref}
          line -> {:ok, line |> String.split() |> List.first()}
        end

      {:ok, {out, rc}} ->
        {:error, {rc, String.trim(out)}}

      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, {:exit, reason}}
    end
  end
end
