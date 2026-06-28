defmodule Fleet.Pilot.StageDispatcher do
  @moduledoc """
  Dispatch `ticket assigné → spawn le rôle de la carte` : la forge EST la machine à états, ce module
  réagit à ses transitions. Le poller voit un ticket **assigné-à-moi** (scoping multi-user porté
  forge-side, en amont), non verrouillé, et le pousse à son stage courant.

  ## Décision (`decide/1`) — PORTE pure

  À partir du payload d'une issue Gitea : `:engage` (procéder) | `{:skip, reason}` (`:in_flight` verrou posé,
  `:awaits_arch` verrou humain). decide ne fait QUE la porte — pas d'ownership (scoping forge-side amont),
  pas de rôle ni de load (le RÔLE vient de la POSITION carte, via `carte_role` ; voir Effets).

  ## Effets (`dispatch_issue/2`)

  Sur `:engage` : résout projet + route, puis :
    * **route absente** (issue routeless — create_ticket ne grave plus, ou ticket humain brut) →
      `ensure_carte_or_onboard` grave la **carte par défaut** (mandate-gate) → `{:skipped, :onboarded}`
      (on défère ; le tick suivant la voit routée). C'est l'ENTRÉE système : create_ticket crée, le poller route.
    * **route présente** → `carte_role` dérive `{role, profile, stage_spec}` de la POSITION carte (PAS de
      producteur en dur — la route décide ; route absente à ce point = anomalie → fail-loud, jamais l'eng en
      silence), puis l'**ordre canonique du spawn** (label `lcars-in-flight` AVANT pod, sinon double-spawn).

  Les juges sont dispatchés PR-driven via `dispatch_review` (requested_reviewers). Les modules
  `:forge_client` / `:loader` / `:carte_loader` / `:spawner` sont des **seams** (défauts = modules réels).
  """

  require Logger

  # Vocabulaire protocole = source unique Fleet.Pilot.Labels (constantes compile-time).
  @in_flight_label Fleet.Pilot.Labels.in_flight()
  @awaits_arch_label Fleet.Pilot.Labels.awaits_arch()

  @type decision :: :engage | {:skip, atom()}

  @doc """
  Décision PURE (porte) : payload issue → `:engage` | `{:skip, reason}`. decide ne fait QUE la
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

      # Verrou HUMAIN (verdict gatekeeper escalate/halt/redirect, ou anomalie). L'issue attend
      # une action via l'arch ; le poller NE re-dispatche PAS (sinon boucle de jugement après l'unlock).
      @awaits_arch_label in labels ->
        {:skip, :awaits_arch}

      true ->
        :engage
    end
  end

  @doc """
  Dispatch effectif d'une issue : `decide/1` puis, sur `:engage`, résout projet+route et soit ONBOARDE
  (routeless → grave la carte par défaut → skip), soit dérive le rôle de la carte (`carte_role`) et
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

    # Chargeur de carte injectable (seam, comme les autres) — rend `carte_role` testable sans disque.
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
        # de verrou orphelin. project = base_sha pinné (hors-pod) ; route = (pipeline, stage) gravée forge-side.
        # ROUTELESS = pas encore onboardée (create_ticket ne grave plus) → `ensure_carte_or_onboard`
        # grave la carte par défaut + renvoie `{:onboarded, _}` → on DÉFÈRE (skip ; le tick suivant la voit
        # routée). Routée → `carte_role` dérive le rôle de la POSITION carte (PAS de producteur en dur ;
        # route absente à ce point = anomalie post-onboard → fail-loud, JAMAIS l'eng en silence).
        # Route + carte pré-lues par le poller (classification du bail) → réutilisées via opts
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
               ),
             # Identité du pod + sérialisation LUES du catalogue (`slot_scope`), jamais devinées :
             # `pod_id_for_scope/4` (instance → for_issue, fan-out par ticket | project → for_repo, UNE
             # identité par projet) et `serialize_project_scope/3` (gate AVANT tout verrou : un rôle
             # project-scoped déjà vivant → on défère `{:skipped, :role_busy}`, sinon on verrouillerait
             # une issue qu'on ne traite pas ; le poller re-dispatch au tick suivant).
             scope = Fleet.CapProfile.slot_scope(profile),
             pod_id = pod_id_for_scope(scope, repo, number, role),
             :ok <- serialize_project_scope(scope, spawner, pod_id) do
          # pod_id et branche (`lcars/issue-N-role`) construits indépendamment depuis (n, role) ; pod_id
          # opaque (jamais re-parsé). La branche reste repo-LOCALE (pas de collision intra-repo).

          # La FORME du mandat (worker exécutable | juge désamorcé) est lue du cap-profile
          # (`mandate_kind`), PAS d'un nom magique "gatekeeper" en ring2 (differentiation-par-catalogue).
          # Calculé UNE fois → sert au spawn-file ET au brief TaskQueue (que le pod pull via get_task).
          # Sans ça, enqueue_mandate ré-enqueuerait `issue["body"]` brut → un juge pullerait le mandat BUILD
          # exécutable au lieu du GateBrief.
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
              # Nom de branche LOCALE parlant (titre du ticket sanitizé), pas
              # le pod_id. Sert à phase.ex → `feature/<slug>`.
              slug: feature_slug(issue)
            ]
            |> maybe_put_project(project)
            |> maybe_put_route(route)
            |> maybe_put_repo_id(resolve_repo_id(forge, repo, forge_opts))

          # Spawn LEAF partagé avec dispatch_by_verdicts (verrou → pod → enqueue → wake +
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
              # Seam de recovery de wake (défaut = la vraie fn) threadé depuis opts.
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
          {:skipped, :role_busy} ->
            # Rôle project-scoped déjà occupé par un autre ticket du repo → DÉFÉRÉ sans verrou ni
            # enqueue ; le poller re-dispatch au tick suivant (sérialisation par-(repo,rôle) via la
            # boucle de poll ; le pod one-shot meurt en fin de tâche → spawn frais pour le suivant).
            {:skipped, :role_busy}

          {:onboarded, _stage} ->
            # Issue routeless onboardée sur la carte par défaut → on DÉFÈRE (skip ; le tick suivant
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
  Dispatch PR-driven d'un JUGE (switch review-request). Une PR ouverte avec une review
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
      # Seam de recovery de wake (défaut = la vraie fn) threadé depuis opts.
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      opts: opts
    }

    pr_number = pr["number"]
    head = get_in(pr, ["head", "ref"]) || ""
    head_sha = get_in(pr, ["head", "sha"])
    labels = Enum.map(Map.get(pr, "labels") || [], & &1["name"])

    # Le SET des juges NE se lit PAS du seul `requested_reviewers` : Gitea altère ce champ de façon
    # NON FIABLE (un juge peut en DISPARAÎTRE sans avoir voté → merge sur demi-jury). Source
    # STABLE = les review-records (`pr_review_state.reviewers`, REQUEST_REVIEW inclus). On garde
    # `requested_reviewers` en UNION (défensif : un fraîchement-demandé pas encore dans les records). Logins↓.
    requested_field = pr |> Map.get("requested_reviewers") |> List.wrap() |> Enum.map(&login_of/1)

    # Pas de check d'ownership ici : le scoping PR est FORGE-SIDE en amont (list_open_pulls ne rend
    # QUE mes PR via /issues?type=pulls&assigned_by). dispatch_review ne fait que du dispatch de jugement.
    cond do
      @in_flight_label in labels ->
        {:skipped, :in_flight}

      # L'ISSUE parente porte `lcars-awaits-arch` (escalade : verdict gatekeeper
      # escalate/halt/redirect, ou conflit non auto-résolu) → on NE re-dispatch PAS le juge (sinon churn :
      # re-spawn par tick). SYMÉTRIQUE de `decide/1` côté issue. Le SET vient du POLLER (issues déjà
      # listées au tick → `:awaits_arch_ids`, ZÉRO I/O ajouté) ; absent (autres callers/tests) → `MapSet.new()`
      # → comportement inchangé (back-compat). On lit le label sur l'ISSUE, pas sur la PR : c'est l'issue qui
      # gèle (l'escalade pose le verrou humain dessus), la PR n'en sait rien — d'où l'aveuglement sinon.
      awaits_arch_issue?(head, opts) ->
        {:skipped, :awaits_arch}

      true ->
        # head_sha → verdicts COMMIT-SCOPÉS : une review sur un commit antérieur (REQUEST_CHANGES jamais
        # dismissé par Gitea au push) est PÉRIMÉE → son juge redevient `pending` → re-dispatché sur le code
        # courant (sinon rework infini).
        verdict_opts = Keyword.put(ctx.forge_opts, :head_sha, head_sha)

        case ctx.forge.pr_review_state(ctx.repo, pr_number, verdict_opts) do
          {:ok, %{verdicts: verdicts, reviewers: jury}} ->
            # SET des juges = union(requested_reviewers VOLATIL, review-records STABLES). Un juge
            # tombé de `requested_reviewers` sans voter reste dans le jury → `pending` → spawné, jamais un
            # merge sur demi-jury (cf. ForgeClient.pr_review_state).
            requested = Enum.uniq(requested_field ++ jury)
            dispatch_by_verdicts(requested, verdicts, pr_number, head, ctx)

          {:error, reason} ->
            {:error, {:review_state, reason}}
        end
    end
  end

  # L'issue parente de la PR (déduite de `head.ref` = `lcars/issue-<n>-<role>`) attend-elle
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

  # Aiguillage REVIEWS-DRIVEN (la source de vérité = les reviews postées, PAS `requested_reviewers`
  # que Gitea ne vide pas). Sans branch-protection : LCARS agrège (décision user). ORDRE :
  #   1. un juge demandé SANS verdict décisif → round actif → on le spawn (sérialisé par le verrou PR).
  #      Un juge déjà décisif (même encore listé dans requested_reviewers) n'est PAS re-spawné → fin de
  #      la boucle de re-spawn.
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
        # Tous approuvé → MERGE. Si le merge échoue sur un CONFLIT (PR approuvée mais
        # `main` a avancé + même fichier édité), on ne remonte PAS l'erreur sèche (= retry-à-l'infini avec un
        # sceau mensonger). On RÉSOUT (rebase producteur), borné par l'IncidentRegistry (récurrence → escalade arch).
        case promote_pr(pr_number, head, ctx) do
          {:error, {:merge, reason}} -> dispatch_conflict_resolution(pr_number, head, reason, ctx)
          other -> other
        end
    end
  end

  # Rework juge : la PR porte un verdict REQUEST_CHANGES courant (l'état a déjà été lu par
  # `dispatch_review` → pas de re-lecture ici) -> le PRODUCTEUR (role git_native de head.ref) reprend
  # pour corriger sur la même PR. Idempotent (verrou PR).
  #
  # FREIN ANTI-CHURN. Sans compteur, `dispatch_rework` re-spawnerait le producteur à chaque tick — le frein
  # `rebound` (budget carte, HopConsumer) n'est jamais appelé sur CE chemin (PR-review-driven) → rework
  # INFINI si l'eng ne satisfait jamais le juge, sans escalade. On borne les rounds par un compteur
  # FORGE-NATIF (`count_change_request_rounds` = nb de reviews REQUEST_CHANGES, monotone) aligné sur le frein
  # carte (budget = `max_rework_rounds`, défaut 2, configurable via `:max_pr_rework_rounds`). Au-delà du
  # budget → ESCALADE ARCH (label `awaits-arch` + commentaire), pas de re-spawn → fin du churn. Budget
  # illisible (`{:error}`) → on NE re-spawn PAS à l'aveugle : escalade (symétrique de `rebound` qui surface).
  defp dispatch_rework(pr_number, head, ctx) do
    case Fleet.Pilot.ForgeClient.parse_feature_branch(head) do
      {:ok, {_n, producer_role}} ->
        budget = Keyword.get(Map.get(ctx, :opts, []), :max_pr_rework_rounds, 2)

        case ctx.forge.count_change_request_rounds(ctx.repo, pr_number, ctx.forge_opts) do
          {:ok, rounds} when rounds <= budget ->
            dispatch_pr_role(:rework, pr_number, head, producer_role, ctx)

          {:ok, rounds} ->
            escalate_rework_to_arch(pr_number, head, %{rounds: rounds, budget: budget}, ctx)

          {:error, reason} ->
            # Budget non vérifiable → on n'entre pas dans une boucle aveugle : on remonte à l'arch.
            escalate_rework_to_arch(pr_number, head, {:budget_unreadable, reason}, ctx)
        end

      :error ->
        {:skipped, :not_fleet_branch}
    end
  end

  # Rework PR épuisé (rounds > budget, ou budget illisible) → l'arch tranche. Symétrique de
  # `escalate_conflict_to_arch` : commentaire gatekeeper dédupliqué + verrou `lcars-awaits-arch` sur l'ISSUE
  # (le poller la SKIP, plus de re-dispatch). Retour `{:skipped, _}` (forme gérée par le poller).
  defp escalate_rework_to_arch(pr_number, head, detail, ctx) do
    with {:ok, {issue_n, _producer}} <- parse_feature_branch_or_skip(head) do
      signature = "[rework-exhausted-escalation:pr-#{pr_number}]"

      body =
        "**Architecte** — ⚠ Rework non convergent sur la PR ##{pr_number} (issue ##{issue_n}) : le budget " <>
          "de rounds de review est épuisé (`#{inspect(detail)}`). Le producteur ne satisfait pas les juges. " <>
          "Reprends : re-cadre le mandat, tranche le désaccord, ou ferme la PR. L'issue reste hors-dispatch " <>
          "tant que `lcars-awaits-arch` est posé.\n\n" <> signature

      escalate_to_arch(issue_n, signature, body, ctx)
      {:skipped, {:rework_exhausted_escalated, pr_number}}
    end
  end

  # Merge KO sur conflit (PR approuvée, `main` avancé sous une PR parallèle touchant le
  # même fichier). Borné par l'IncidentRegistry (cross-session, work/ops) :
  #   1ʳᵉ occurrence → `:recorded` → dispatch le PRODUCTEUR en `:resolve_conflict` (rebase + résous ; le push
  #     rebasé invalide les vieilles reviews via head_sha → les juges re-valident le fusionné, gatekeeper scelle
  #     au tick suivant) ;
  #   récurrence → `{:escalated, _}` (résolution déjà tentée, conflit persiste) → ESCALADE ARCH. PAS de boucle.
  defp dispatch_conflict_resolution(pr_number, head, reason, ctx) do
    # Le n° de PR est encodé DIGIT-FREE (base-26 a..z) DANS le subject. `IncidentRegistry.signature`
    # passe le subject par `normalize` (`~r/\d+/ → "N"`, PARTAGÉ pod/wake — on ne le touche PAS) : un `pr-8`
    # décimal deviendrait `pr-N` ≡ `pr-12` → après le 1er conflit d'un repo, TOUTE PR suivante en conflit serait
    # vue « récurrente » → escaladée arch au lieu d'être résolue (la résolution parallèle neutralisée dès le
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
        resolve_first_conflict(head, pr_number, ctx)

      {:record_failed, e} ->
        # Registre indisponible : l'incident n'est PAS mémorisé (une récurrence ne sera pas détectée),
        # mais c'est bien une 1re occurrence → on tente quand même la résolution. On le CRIE.
        Logger.error(
          "StageDispatcher merge-conflict #{subject} : incident NON gravé (registre indisponible) — " <>
            "1re résolution tentée SANS mémoire (récurrence non détectable) : #{inspect(e)}"
        )

        resolve_first_conflict(head, pr_number, ctx)

      {:escalated, _} ->
        escalate_conflict_to_arch(pr_number, head, reason, ctx)

      {:escalation_failed, e} ->
        # Récurrence DÉTECTÉE (le conflit persiste) → on escalade à l'arch comme prévu. Mais le ticket
        # sysadmin (error_system) n'a PAS pu être ouvert (forge down ?) — on le CRIE, on ne rassure pas.
        Logger.error(
          "StageDispatcher merge-conflict #{subject} RÉCURRENT mais ticket sysadmin ÉCHOUÉ — AUCUN " <>
            "ticket error_system créé (forge down ?) ; escalade arch tentée tout de même : #{inspect(e)}"
        )

        escalate_conflict_to_arch(pr_number, head, reason, ctx)
    end
  end

  # 1re occurrence d'un conflit : on tente la résolution (re-spawn du producteur en mode rebase/résous).
  # Partagé entre `:recorded` (incident gravé) et `{:record_failed, _}` (registre indisponible — on tente
  # quand même, c'est bien un 1er passage du point de vue dispatch).
  defp resolve_first_conflict(head, pr_number, ctx) do
    case Fleet.Pilot.ForgeClient.parse_feature_branch(head) do
      {:ok, {_n, producer_role}} ->
        dispatch_pr_role(:resolve_conflict, pr_number, head, producer_role, ctx)

      :error ->
        {:skipped, :not_fleet_branch}
    end
  end

  # Encode un n° de PR en LETTRES (base-26 bijective a..z) → DIGIT-FREE, donc INVISIBLE à `normalize`
  # (`~r/\d+/ → "N"`) côté IncidentRegistry. Bijectif (chaque numéro → une chaîne unique : 1→a … 26→z, 27→aa)
  # → deux PR distinctes ont des clés incident DISTINCTES (l'invariant qui isole les conflits par PR).
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

      escalate_to_arch(issue_n, signature, body, ctx)

      # `{:skipped, _}` = forme GÉRÉE par le poller (stage_process_pulls) → compté skipped, pas de crash.
      # Un `{:escalated, _}` ne serait dans AUCUNE clause du `case do_poll` → CaseClauseError à chaque tick :
      # un retour de dispatch DOIT être {:ok|:skipped|:error}, jamais une 4ᵉ forme.
      {:skipped, {:merge_conflict_escalated, pr_number}}
    end
  end

  # CŒUR d'escalade arch (factorisé — conflit ET rework épuisé) : commentaire gatekeeper DÉDUPLIQUÉ
  # (signé via `as_role`) + verrou `lcars-awaits-arch` sur l'ISSUE → le poller la SKIP
  # (hors-dispatch). Best-effort : on remonte au canal humain (l'arch), on ne masque pas. Un seul point d'écriture
  # forge pour toutes les escalades arch PR (pas de fork de signature/label).
  defp escalate_to_arch(issue_n, signature, body, ctx) do
    gk_opts =
      ctx.forge_opts
      |> Fleet.Pilot.ForgeClient.as_role(Fleet.Pilot.GatekeeperSeal.gatekeeper_role())
      |> Keyword.put(:dedup_signature, signature)
      |> Keyword.put(:dedup_any_author, true)

    _ = ctx.forge.post_comment(ctx.repo, issue_n, body, gk_opts)
    _ = ctx.forge.add_label(ctx.repo, issue_n, @awaits_arch_label, ctx.forge_opts)
    :ok
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
    # Spawner/task_queue ne sont pas lus ici directement : ils transitent via `ctx` vers `spawn_stage`.
    %{
      repo: repo,
      forge: forge,
      resolver: resolver,
      forge_opts: forge_opts,
      opts: opts
    } = ctx

    # Le pod review (juge) OU rework (producteur) clone la FEATURE-BRANCH (`head.ref`), PAS
    # `main` : le juge doit voir le DIFF du producteur (sinon il juge `main`, c.-à-d. rien de réel) ;
    # le rework reprend SON propre travail. Read-only sur le code via le workspace provisionné par le
    # système (le pod n'a aucun token forge). `base_branch: head` → le pod CLONE et
    # part du tip de la feature-branch.
    #
    # La RÉSOLUTION (rebase) part AUSSI de la feature (son travail à rebaser),
    # mais son livrable doit DESCENDRE de `main` (la cible du rebase), pas de l'ancien tip de feature
    # (réécrit par le rebase → la gate le rejetterait : `base_not_ancestor`). On
    # DÉCONFLE les deux rôles autrement portés par `base_sha` : `base_branch` = clone-base (feature, le pod
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
      # pod_id : rework/conflict = le PRODUCTEUR, routé par `slot_scope` (project → for_repo = MÊME
      # identité que dispatch_issue, UNE par projet ; instance → for_issue). Le JUGE keye sur la PR
      # (for_pr, fan-out par review). Le rework re-lit son état DEPUIS LA FORGE (PR + findings) →
      # changer l'identité du pod ne perd aucun contexte.
      pod_id =
        case kind do
          k when k in [:rework, :resolve_conflict] ->
            pod_id_for_scope(Fleet.CapProfile.slot_scope(profile), repo, issue_n, role)

          _ ->
            Fleet.Pilot.PodId.for_pr(repo, pr_number, role)
        end

      # Gate de sérialisation (MÊME règle que dispatch_issue) : un producteur project-scoped déjà vivant
      # (occupé par un autre ticket) → on DÉFÈRE, jamais re-mandater-pendant-occupé. Juges (instance) et
      # rework instance → `:ok` (no-op, jamais gated). Appel uniforme via `slot_scope`. `{:skipped,
      # :role_busy}` remonte au poller (qui gère `{:skipped, _}` → retry au tick suivant).
      case serialize_project_scope(Fleet.CapProfile.slot_scope(profile), ctx.spawner, pod_id) do
        {:skipped, :role_busy} ->
          {:skipped, :role_busy}

        :ok ->
          # :judge -> GateBrief désamorcé ; :rework -> brief au PRODUCTEUR (corrige + push).
          mandate =
            review_mandate(
              kind,
              profile,
              role,
              forge,
              repo,
              issue_n,
              forge_opts,
              route,
              pr_number
            )

          spawn_opts =
            [mandate: mandate, pod_id: pod_id, rc_name: rc_name(repo, role)]
            |> maybe_put_project(project)
            |> maybe_put_route(route)
            |> maybe_put_repo_id(resolve_repo_id(forge, repo, forge_opts))

          # Spawn LEAF partagé avec dispatch_issue (verrou → pod → enqueue → wake + compensation).
          # Verrou keyé sur la PR (pr_number) ; ticket_id + enqueue keyés sur l'ISSUE (issue_n — le
          # pipeline-state y reste).
          log_ctx = "review pr=#{repo}##{pr_number} issue=##{issue_n}"

          spawn_stage(
            ctx,
            pod_id,
            role,
            profile,
            mandate,
            spawn_opts,
            pr_number,
            issue_n,
            log_ctx
          )
      end
    else
      {:error, {phase, reason}} ->
        Logger.warning(
          "StageDispatcher: #{phase} review role=#{role} pr=#{repo}##{pr_number} → #{inspect(reason)} (skip, pas de verrou)"
        )

        {:error, {phase, reason}}
    end
  end

  # DÉCONFLATION clone-base / gate-base. Une RÉSOLUTION (rebase) part de la
  # feature (clone-base, son travail) mais son livrable doit DESCENDRE de `main` (cible du rebase) → la
  # gate se base sur `main`, pas sur l'ancien tip de feature (réécrit par le rebase, donc pas
  # ancêtre). judge/rework (forward, pas de réécriture) : aucune divergence → gate = clone-base.
  defp maybe_gate_base_main(opts, :resolve_conflict),
    do: Keyword.put(opts, :gate_base_branch, "main")

  defp maybe_gate_base_main(opts, _kind), do: opts

  # PROMOTE PR-state-driven (interim, sans branch-protection) : tous les juges ont
  # approuvé → le système SCELLE. Comment de fin + merge signés GATEKEEPER
  # (gardien des PRs — « c'est dans son nom » ; token de rôle, `as_role`). Comment HONNÊTE
  # (on ne ment pas, on montre) : livré par l'eng, validé par les juges (APPROVED), mergé
  # par le système (branch-protection OFF en dev → LCARS agrège, pas Gitea — explicité). Le merge
  # `rebase` (LINÉAIRE, gère un `main` avancé sous une PR parallèle — multi-ticket, cf. merge_pr)
  # auto-close l'issue via `Closes #N` du body PR → close APRÈS merge, jamais avant. Pas de verrou
  # (poller mono-process) ; PR déjà mergée → 409 → la PR disparaît au tick suivant (idempotent).
  defp promote_pr(pr_number, head, ctx) do
    with {:ok, {issue_n, producer}} <- parse_feature_branch_or_skip(head) do
      # Sceau UNIQUE partagé avec `HopCompleter.promote` : commentaire gatekeeper + merge
      # signé gatekeeper. Un chemin de merge séparé forkerait en token système (l'escalade signerait `system`).
      gk_opts =
        Fleet.Pilot.ForgeClient.as_role(
          ctx.forge_opts,
          Fleet.Pilot.GatekeeperSeal.gatekeeper_role()
        )

      case Fleet.Pilot.GatekeeperSeal.seal_and_merge(
             ctx.forge,
             ctx.repo,
             pr_number,
             issue_n,
             producer,
             gk_opts
           ) do
        :ok ->
          # Die-on-promote (best-effort). Le producteur est `one-shot` : il est DÉJÀ mort en fin de
          # build/rework → ce kill est un no-op dans le cas nominal. On garde DÉLIBÉRÉMENT `for_issue`
          # (pas `for_repo`) : pour un producteur `slot_scope: project`, `for_issue(issue_n, producer)`
          # cible un pod_id PHANTÔME (`<repo>-issue-N-engineer` n'existe pas — l'identité projet est
          # `<repo>-engineer`) → no-op SÛR. Utiliser `for_repo` ici TUERAIT l'eng s'il code déjà une
          # AUTRE issue (pod projet partagé) = bug « kill the wrong eng ». À revisiter SEULEMENT si un
          # producteur PIPE (long-lived) est réintroduit (cleanup ciblé non-naïf nécessaire alors).
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

  # `promote_comment` + le rôle gatekeeper + le merge vivent dans `Fleet.Pilot.GatekeeperSeal`
  # (sceau UNIQUE partagé avec `HopCompleter.promote` — pas de fork de signature de merge).

  # Nom RC Desktop = `<projet>_<role>` (projet = segment final du repo, ex.
  # `fleet/poc-8` → `poc-8`). Label EXACT (claude_launch → `--remote-control "<nom>"`, zéro suffixe
  # auto). Distinct du pod_id (clé technique repo-scopée) ; ici c'est le label humain-lisible Desktop.
  defp rc_name(repo, role), do: "#{project_name(repo)}_#{role}"

  # Nom de projet path/name-safe (charset [A-Za-z0-9-], zéro espace/`/`/`_`).
  # Segment final du repo, sanitizé. C'est LA source du `<project>` partout en aval (nom RC Desktop,
  # SANDBOX_HOME `/home/<project>`, seed-store, branche) via `rc_name` → un seul point de vérité, propre.
  # Pas de `_` (séparateur de rc_name `<project>_<role>` → garderait l'ambiguïté).
  defp project_name(repo),
    do: repo |> String.split("/") |> List.last() |> String.replace(~r/[^A-Za-z0-9-]/, "-")

  # Slug parlant du titre du ticket pour la branche LOCALE (`feature/<slug>`).
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

  # `repo_id` = id forge du projet → session_id déterministe des rôles project-bound
  # (eng, juges) via `Fleet.Spawner.SessionId` (segment `<REPO4>` DÉCIMAL). Forge sans `repo_id`/2
  # (stub) / forge down / id absent → `nil` → pas de `repo_id` posé. Un rôle project-bound spawné SANS
  # repo est alors une ANOMALIE : le mint (`deterministic_session_id`) FAIL-LOUD (raise) — on ne fabrique
  # JAMAIS un UUID random pour masquer une forge non résolue (forge = organe de LCARS, forge down = stop).
  # `rem(id, 10000)` : `<REPO4>` = 4 chiffres décimaux → DETTE assumée, le
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

  # Mandat d'un dispatch PR : :judge -> GateBrief desamorce (via build_mandate, le pod
  # juge l'issue) ; :rework -> brief de rework au PRODUCTEUR (corrige selon la review, re-pousse).
  # Chemin PR-juge — pas de stage carte ici (juges PR-driven) → `stage_spec = %{}` :
  # build_mandate retombe sur le `mandate_kind` du profil (judge pour qualifier/reviewer) ET sur le
  # `judge_target` par défaut (deliverable) → build_judge_mandate (juge le livrable/PR).
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

  # Brief de rework : le PRODUCTEUR (engineer) reprend sur une PR REQUEST_CHANGES.
  # PORTE LA MÊME instruction git-native que `build_worker_mandate` (sinon `:no_deliverable_commit` : le
  # rework « re-pousse » mais le pod est FORGE-AVEUGLE et sans l'ordre de COMMITTER il ne livre rien —
  # jumeau du mandat producteur). Le pod corrige + commite EN LOCAL ; le SYSTÈME pousse (frontière
  # forge). Trailer obligatoire (gate de push).
  #
  # FAMINE D'INFO, moitié rework : sans le BODY des reviews REQUEST_CHANGES,
  # « corrige selon la review » est creux — le pod forge-aveugle ne voit PAS la review → il devine à
  # l'aveugle (un eng prudent refuse de deviner → `blocked_dep` → wedge). On lit le feedback sur la forge
  # (le runtime, pas le pod : frontière forge préservée) et on l'injecte. Si la lecture échoue / aucun body,
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

  # Brief de RÉSOLUTION DE CONFLIT : la PR est APPROUVÉE mais `main` a avancé (un
  # autre ticket parallèle a fusionné) → conflit. Le PRODUCTEUR (git_native, il a écrit le contenu) RÉCONCILIE :
  # rebase sur `main` + résolution en gardant TOUT (le sien + main). Pas un re-code. Le système pousse ;
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
  # a une voix pour l'humain. Sans ça il est muet sur la forge (un diagnostic même excellent ne serait
  # jamais vu) ; feedback verbeux, descriptif, traçable.
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

  # La forme du mandat est une propriété du rôle (cap-profile `mandate_kind`), PAS un nom
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
    # Le `mandate_kind` du STAGE (carte) PRIME sur celui du profil (override per-stage) — réutilise
    # un profil worker (consultant) en JUGE sans profil-doublon. ABSENT au stage → défaut profil
    # (lui-même "worker" par défaut, fail-safe) via le `||` : l'absence n'est PAS une anomalie. Ce
    # qui suit traite la valeur PRÉSENTE-mais-hors-vocab, distincte de l'absence.
    kind = Map.get(stage_spec, "mandate_kind") || Fleet.CapProfile.mandate_kind(profile)

    # Somme TOTALE et fail-loud. La judge-ness (et la cible d'un juge) est une propriété de
    # SÉCURITÉ : elle ne s'infère JAMAIS par omission de clause. Un kind/target hors-vocab (typo, ou
    # valeur d'un futur vocabulaire) NE DOIT PAS retomber silencieusement sur worker — sinon un rôle
    # juge recevrait un corps d'issue EXÉCUTABLE (mandat actif) au lieu d'un brief désamorcé. On
    # rejette bruyamment (raise) plutôt que de construire un mandat dangereux en silence.
    case {kind, Map.get(stage_spec, "judge_target")} do
      # Juge de MANDAT (judge_target:mandate) → juge le ticket.body (exécutable ?), PAS un livrable
      # (pas de code en amont).
      {"judge", "mandate"} ->
        build_mandate_review_mandate(role, issue, forge, repo, number, forge_opts, route)

      # Juge de LIVRABLE : judge_target ABSENT (nil → défaut canon) ou "deliverable" explicite →
      # juge un livrable (PR), brief inchangé.
      {"judge", target} when target in [nil, "deliverable"] ->
        build_judge_mandate(role, forge, repo, number, forge_opts, route)

      # judge_target PRÉSENT mais hors {mandate, deliverable} → anomalie : on ne devine pas la cible.
      {"judge", other} ->
        raise ArgumentError,
              "judge_target #{inspect(other)} hors vocabulaire {mandate, deliverable} — la cible d'un juge ne s'infère pas"

      {"worker", _} ->
        build_worker_mandate(role, issue)

      # kind ∉ {worker, judge} (mandate_kind présent mais hors-vocab) → fail-loud.
      {other, _} ->
        raise ArgumentError,
              "mandate_kind #{inspect(other)} hors vocabulaire {worker, judge} — la judge-ness ne s'infère pas"
    end
  end

  # Mandat producteur = le brief de l'issue + l'instruction de LIVRAISON git-native. Sans elle,
  # le pod « submit les contenus » au lieu de
  # COMMITTER → la publish git_native ne trouve aucun commit (`:no_deliverable_commit`).
  # Le pod commite en LOCAL ; le SYSTÈME pousse + ouvre la PR (forge-aveugle). Le trailer
  # est obligatoire (gate de push, source unique `ForgeIdentity.coauthor_instruction`).
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

  # Un pod **juge** doit savoir QUOI
  # juger ET comment rendre son verdict. On réutilise le brief canonique `Fleet.Pipeline.GateBrief`
  # (contexte + livrable + question + **contrat `gate-decision-v1.json` + options canon**) — le même
  # que le modèle RAM. Le `result_K` à juger est lu du comment du hop précédent (gravé par
  # HopCompleter) ; le pod reste forge-aveugle (le runtime lit le comment, pas de
  # clone).
  defp build_judge_mandate(role, forge, repo, number, forge_opts, route) do
    predecessor =
      case forge.get_predecessor_result(repo, number, forge_opts) do
        {:ok, result} when is_map(result) and map_size(result) > 0 -> result
        _ -> nil
      end

    # GIT-NATIVE (predecessor vide) : le livrable N'EST PAS un payload — c'est le CODE de la
    # branche. Le juge clone la feature-branch + a `Bash(git diff/log/show)` → on le POINTE sur son
    # workspace au lieu de lui donner `{}` (sur quoi il fail-closerait `halt_wait_input`). Sinon il juge
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
    # DÉSAMORCÉ (contexte, pas instruction exécutable → l'état exécutable est rendu irreprésentable) → le juge sait CONTRE QUOI juger.
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

    # Le mandat du juge ne doit contenir AUCUNE instruction exécutable (état exécutable rendu
    # irreprésentable en amont). Le `request` (body de l'issue = critère) est rendu par GateBrief DÉSAMORCÉ
    # (blockquote « CONTEXTE — déjà traité, NE PAS exécuter » + bannière « JUGER, PAS PRODUIRE »). Le risque
    # vise un juge **base-worker** (profile noop, gatekeeper) qui RE-exécuterait le build même quoté : ce
    # juge-là reçoit son brief par `dispatch_gatekeeper` (hop_consumer) qui NE passe PAS `request` — il
    # n'est pas affecté ici. `build_judge_mandate` ne sert que les juges À PERSONA (qualifier/reviewer,
    # `subagent_template` spec-reviewer/code-quality-reviewer) — le cas réputé SÛR
    # (un juge à vraie persona : GateBrief sait rendre `request` désamorcé). En pratique
    # ces juges fail-closent `halt_wait_input` sur livrable vide, ils ne RE-buildent pas.
    # Sans le critère (`request`) ET le livrable (diff via `outputs`), le juge jugerait du `{}` → rework
    # infini (le Reviewer ne peut JAMAIS `continue` sur du vide) — c'est la famine d'info.
    Fleet.Pipeline.GateBrief.build(%{
      stage: stage,
      pipeline_id: pipeline,
      gate: nil,
      outputs: outputs,
      request: request
    })
  end

  # Mandat d'un juge de MANDAT (mandate-review, judge_target:mandate). Le consultant juge le MANDAT
  # (ticket.body rédigé par l'arch) AVANT que l'engineer ne parte : exécutable sans nouvelle question ? On
  # réutilise le MÊME GateBrief (contrat gate-decision-v1 + options canon) que les autres juges — seul le
  # `subject: :mandate` recadre le « truc à juger ». Le MANDAT va dans `outputs` (le truc À JUGER ; ≠
  # build_judge_mandate où outputs = le livrable/code) ; pas de `request` (le critère d'exécutabilité est
  # porté par le cadrage :mandate). Le juge est PRÉ-PR (aucun clone, aucun livrable) → cohérent N0.
  defp build_mandate_review_mandate(role, issue, forge, repo, number, forge_opts, route) do
    # Le mandat = body de l'ISSUE, DÉJÀ en main (le poller a listé l'issue ; mandate-review est
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

  # Body de l'issue DÉJÀ listée par le poller → utilisé direct ; fetch SEULEMENT en fallback
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

  # Carte-driven role : dérive `{role, profile, stage_spec}` de la POSITION carte (route gravée) +
  # load du profil. route nil = anomalie → fail-loud (pas de fallback producteur). Carte/stage/
  # profil non résolus = misconfig → `{:error, _}` (fail-loud).
  # `prefetched_carte` : carte déjà chargée par le poller (classification du bail) → on évite un
  # 2ᵉ load ; `nil` (tests, autres callers) → chargement via `carte_loader` (fallback).
  @spec carte_role(
          {String.t(), String.t()} | nil,
          (String.t() -> {:ok, Fleet.CapProfile.t()} | {:error, term()}),
          (String.t() -> map()),
          map() | nil
        ) :: {:ok, {String.t(), Fleet.CapProfile.t(), map()}} | {:error, term()}
  # Route nil = ANOMALIE : le poller onboarde tout routeless AVANT dispatch (ensure_carte_or_onboard)
  # → si on arrive ici sans route, fail-loud, JAMAIS un fallback eng silencieux. Le rôle vient TOUJOURS de la
  # position carte (route gravée).
  defp carte_role(nil, _load_role, _carte_loader, _prefetched_carte), do: {:error, :unrouted}

  defp carte_role({pipeline, stage}, load_role, carte_loader, prefetched_carte) do
    with {:ok, carte} <- carte_or_load(prefetched_carte, pipeline, carte_loader),
         {:ok, role} <- carte_stage_role(carte, pipeline, stage),
         {:ok, profile} <- load_role.(role) do
      # On remonte le STAGE_SPEC entier (extensible) plutôt qu'un champ isolé. build_mandate y
      # lit `mandate_kind` (override per-stage : consultant worker → juge sans profil-doublon) ET
      # `judge_target` (juge le MANDAT vs un livrable). route=nil (producteur initial) → stage_spec vide.
      stage_spec = get_in(carte, ["stages", stage]) || %{}
      {:ok, {role, profile, stage_spec}}
    end
  end

  # Carte pré-chargée (poller) → réutilisée ; sinon chargée via le seam.
  defp carte_or_load(nil, pipeline, carte_loader), do: load_carte(pipeline, carte_loader)
  defp carte_or_load(carte, _pipeline, _carte_loader), do: {:ok, carte}

  # Route pré-lue par le poller (classification) → réutilisée ici ; absente → lecture forge.
  defp resolve_route(opts, forge, repo, number, forge_opts) do
    case Keyword.fetch(opts, :prefetched_route) do
      {:ok, route} -> {:ok, route}
      :error -> route_for(forge, repo, number, forge_opts)
    end
  end

  # Onboarding système. Route présente → passthrough `{:ok, route}`. Route nil (issue routeless :
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

  # Lit la position carte (pipeline, stage) gravée sur la forge. `:none` (hors-carte /
  # 1-stage) → `{:ok, nil}` (producteur direct). Erreur HTTP → propagée (skip sans verrou).
  defp route_for(forge, repo, number, forge_opts) do
    case forge.get_route(repo, number, forge_opts) do
      {:ok, {_p, _s} = route} -> {:ok, route}
      :none -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # Enqueue le mandat dans le broker `Fleet.TaskQueue` ciblé pod_id — le claude REPL le pull via
  # `mcp__fleet__get_task` → `PodTools.get_task` → `TaskQueue.get_for_pod` (PAS un Read fichier).
  # Sans cet enqueue, `TaskQueue.pod_status(pod_id) == nil` → le pod se croit bootstrap
  # (rien à puller) → idle.
  # Le `brief` = le MANDAT role-aware déjà construit (build_mandate) : GateBrief désamorcé pour le
  # gatekeeper, corps de l'issue pour un worker. Un `issue["body"]` brut ferait
  # puller au juge le mandat BUILD exécutable. `metadata.issue` corrèle au ticket.
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

  # Compensation best-effort : tue le pod (s'il a spawné) avant de retirer le verrou.
  # No-op silencieux si le spawner n'expose pas `kill_pod/1` ou si le pod n'existe pas.
  defp safe_kill(spawner, pod_id) do
    if function_exported?(spawner, :kill_pod, 1), do: spawner.kill_pod(pod_id), else: :ok
  rescue
    _ -> :ok
  end

  # Dispatch idempotent. Un pod déjà VIVANT (id déterministe stable) = l'eng pipe long-lived
  # → on le RE-MANDATE (enqueue + wake, garde son contexte), pas de re-spawn (plus de leak/orphelin).
  # `pod_alive?` défaute à `false` si le spawner n'expose pas `pod_info/1` (stubs de test) → chemin
  # spawn inchangé.
  defp pod_alive?(spawner, pod_id) do
    function_exported?(spawner, :pod_info, 1) and match?({:ok, _}, spawner.pod_info(pod_id))
  rescue
    _ -> false
  end

  # Granularité d'identité du pod, dérivée du catalogue (`slot_scope` du cap-profile, source unique) :
  #   "instance" → keyé TICKET (`for_issue`) : fan-out, un id distinct par issue/PR (juges éphémères).
  #   "project"  → keyé REPO seul (`for_repo`) : UNE identité par (repo, rôle) → un slot Desktop stable.
  # Total sur l'enum slot_scope (l'accessor `Fleet.CapProfile.slot_scope/1` garantit project|instance).
  defp pod_id_for_scope("project", repo, _number, role),
    do: Fleet.Pilot.PodId.for_repo(repo, role)

  defp pod_id_for_scope("instance", repo, number, role),
    do: Fleet.Pilot.PodId.for_issue(repo, number, role)

  # Sérialisation des rôles project-scoped : UNE identité (repo, rôle) vivante à la fois (1 slot Desktop
  # ⟹ 1 (cwd, session-id) ⟹ séquentiel). Si le pod projet est DÉJÀ vivant (occupé par un autre ticket),
  # on DÉFÈRE (`{:skipped, :role_busy}`) — AVANT tout verrou/enqueue (sinon on verrouillerait une issue
  # qu'on ne traite pas). Le poller re-dispatch au tick suivant ; le pod one-shot meurt en fin de tâche
  # → spawn frais pour le ticket suivant. Les rôles `instance` ne sont JAMAIS gated (ids distincts par
  # ticket → pas de partage d'identité, fan-out assumé). Appelable UNIFORMÉMENT (instance → :ok no-op).
  defp serialize_project_scope("project", spawner, pod_id) do
    if pod_alive?(spawner, pod_id), do: {:skipped, :role_busy}, else: :ok
  end

  defp serialize_project_scope("instance", _spawner, _pod_id), do: :ok

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

  # LEAF de spawn partagé par dispatch_issue (producteur) ET do_dispatch_review (juge/rework).
  # ORDRE CANONIQUE : label-verrou `lcars-in-flight` AVANT pod (sinon double-spawn) → pod
  # (`maybe_spawn` : RE-MANDATE si vivant) → enqueue du mandat (que le pod pull via get_task) →
  # wake+recovery. Échec POST-verrou → compensation : retrait du verrou (+ kill SI frais spawn,
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

    # Seam d'injection du recovery de wake (défaut = la vraie fn). Même pattern que les seams
    # forge/spawner/task_queue : permet de tester le tally honnête sans hit IncidentRegistry/forge réels.
    wake_recovery = Map.get(ctx, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3)

    ticket_id = Fleet.Pilot.TicketId.compose(ticket_number)
    alive_before? = pod_alive?(spawner, pod_id)

    with {:ok, _} <- forge.add_label(repo, lock_target, @in_flight_label, forge_opts),
         {:ok, _} <- maybe_spawn(spawner, alive_before?, profile, ticket_id, spawn_opts),
         :ok <- enqueue_mandate(task_queue, pod_id, role, ticket_number, mandate) do
      # Le retour de `WakeRecovery.wake` est LOAD-BEARING : `{:error, {:escalated, _}}`
      # (pod injoignable, escaladé à starfleet) ou `{:error, _}` (re-wake KO) signifie que le pod n'est
      # PAS réveillé. Jeter ce retour (`_ = wake(...)`) ferait toujours rendre `spawn_stage`
      # `{:ok, {:spawned}}` → le poller compterait `dispatched +1 / errors 0` MENTEUR (pod jamais réveillé,
      # mais tally clean). On le MATCHE donc : le verrou + le mandat + le pod RESTENT en place (le
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
        # Une étape POST-verrou a échoué → compensation (retrait du verrou, sinon stuck à jamais).
        # Kill SEULEMENT si frais spawn (un re-mandate ne tue JAMAIS l'eng vivant + son contexte).
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
  # Résolution projet (base_sha pinné hors-pod)
  # ============================================================

  # Construit `%{repo_path, base_branch, base_sha}` pour le repo du ticket.
  # `base_url` ← `:forge_opts[:base_url]` ou config app ; `base_branch` ← `:base_branch`
  # (défaut "main"). Pas de forge configurée → `{:ok, nil}` (pod sans repo, ex. tests
  # locaux). L'auth de clone/ls-remote est portée par le runtime (`Fleet.Credentials.ForgeAuth.
  # git_env`, token via env), jamais par le pod (forge-aveugle).
  @spec default_project_resolver(String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def default_project_resolver(repo, opts) do
    forge_opts = Keyword.get(opts, :forge_opts, [])
    base_branch = Keyword.get(opts, :base_branch, "main")

    # DÉCONFLATION clone-base / gate-base. `base_sha` confondrait sinon deux
    # concerns : (1) le POINT DE DÉPART du clone (`pin_base_sha` reset HEAD dessus) et (2) la
    # base de la GATE (HEAD doit en DESCENDRE). Forward (build/rework) : ils coïncident. RÉSOLUTION
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
          # `"repo"` (full_name "owner/name") embarqué dans le projet → il voyage jusqu'au pod
          # puis ressort dans `pod.completed` (`pod_completed_payload`) → le HopConsumer sait sur QUEL
          # repo agir (multi-projet), sans le re-dériver. `repo_path` = l'URL de push (remote per-hop).
          {:ok,
           %{
             "repo" => repo,
             "repo_path" => repo_url,
             "base_branch" => base_branch,
             "base_sha" => sha,
             # gate_base_sha = base de la GATE (≠ clone-base pour une résolution rebase, cf. supra).
             "gate_base_sha" => gate_sha
           }}
        end
    end
  end

  # Base de la GATE. Défaut (forward) : = clone-base (`base_sha`) → la garde exige que HEAD descende
  # de là où le pod a cloné. Un dispatch resolve passe `:gate_base_branch` ("main") → on pinne le tip de
  # CETTE branche (la cible du rebase) : la garde exige alors que HEAD descende de `main`, pas de l'ancien
  # tip de feature (réécrit par le rebase → il ne serait plus ancêtre, d'où un `base_not_ancestor`).
  defp resolve_gate_base_sha(_repo_url, nil, clone_base_sha), do: {:ok, clone_base_sha}

  defp resolve_gate_base_sha(repo_url, branch, _clone_base_sha) when is_binary(branch),
    do: ls_remote_sha(repo_url, branch)

  defp forge_base_url(forge_opts) do
    Keyword.get(forge_opts, :base_url) ||
      get_in(Application.get_env(:fleet_pilot, :forge, []), [:base_url])
  end

  # `git ls-remote <repo_url> <branch>` borné via `Fleet.Credentials.Shell` (source unique de la borne)
  # + auth runtime → SHA du tip (hors-pod). Symétrique du pin de base côté pipeline. Le wrapper lance le
  # ls-remote (RÉSEAU : peut hung/prompter) dans son propre process-group et, à la deadline MUR, tue le
  # GROUPE entier (le ls-remote ET ses helpers de transport, porteurs du token forge) + ferme le port —
  # là où le patron `Task.async` + `shutdown(:brutal_kill)` ne tuait que le Task BEAM en laissant fuir le
  # process git.
  defp ls_remote_sha(repo_url, branch) do
    # Token forge via env (hors argv/cmdline) — source unique Fleet.Credentials.ForgeAuth.
    case Fleet.Credentials.Shell.git(["ls-remote", repo_url, branch],
           timeout_ms: 15_000,
           env: Fleet.Credentials.ForgeAuth.git_env()
         ) do
      {:ok, {out, 0}} ->
        case out |> String.split("\n", trim: true) |> List.first() do
          nil -> {:error, :no_ref}
          line -> {:ok, line |> String.split() |> List.first()}
        end

      {:ok, {out, rc}} ->
        {:error, {rc, String.trim(out)}}

      {:error, {:timeout, _ms}} ->
        {:error, :timeout}

      {:error, {:exit, reason}} ->
        {:error, {:exit, reason}}
    end
  end
end
