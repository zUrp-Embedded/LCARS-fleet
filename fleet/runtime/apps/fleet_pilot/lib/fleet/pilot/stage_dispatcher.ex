defmodule Fleet.Pilot.StageDispatcher do
  @moduledoc """
  Dispatch `ticket assigné → spawn producteur` du modèle forge-state-machine (DN
  `orchestration/forge-state-machine.md` §1). Distinct du `Fleet.Pilot.Dispatcher`
  legacy (route → pipeline nommé) : ici le poller voit un ticket **assigné** (à l'humain owner),
  non verrouillé, et **spawn le rôle PRODUCTEUR** du catalogue (= la brique), sans table de routes.

  ## Décision (`decide/2`)

  À partir du payload d'une issue Gitea, décide :
    * `{:spawn, role, profile}` — un assignee (= l'humain owner), pas de verrou `lcars-in-flight` →
      spawner le **rôle producteur** (`:producer_role`, défaut `"engineer"`).
    * `{:skip, reason}` — `:no_assignee` (aucun owner), `:no_role` (cap-profile producteur
      illisible), `:in_flight` (verrou posé, pod déjà en vol), `:awaits_human`.

  **Invariant DN §1** : le rôle producteur est **invariant** (« la seule cible des tickets code =
  l'eng ») → il vient de la **config** (`:producer_role`), PAS d'un marqueur par-ticket — un label
  `lcars-stage:<role>` ré-encoderait une constante (bruit). L'assignee est l'**humain** (point fixe).
  Les juges, eux, sont dispatchés PR-driven via `dispatch_review` (requested_reviewers), pas ici.

  L'I/O (lecture du cap-profile) est **injectée** via `load_role` (défaut `CapProfile.load/1`)
  → testable sans forge. F075 : le profil chargé pour décider est THREADÉ dans `{:spawn, …}`
  et réutilisé au spawn (pas de second load).

  ## Effets (`dispatch_issue/2`)

  Sur `{:spawn, role, profile}`, applique l'**ordre canonique du spawn** (DN §6, label AVANT
  pod, sinon double-spawn) :
    1. PUT label `lcars-in-flight` (le verrou = machine-state ; PAS de comment-lock dans le
       ticket — le ticket garde du contenu humain, la recovery se fait sur la liveness du pod)
    2. spawn le pod avec le `profile` déjà chargé par `decide` (`Spawner.spawn_pod(profile,
       ticket_id, mandate: …)`)

  Les modules `:forge_client`, `:loader`, `:spawner` sont des **seams** (défauts =
  modules réels) pour tester sans toucher forge ni spawner.
  """

  require Logger

  # F072 : vocabulaire protocole = source unique Fleet.Pilot.Labels (constantes compile-time).
  @in_flight_label Fleet.Pilot.Labels.in_flight()
  @awaits_human_label Fleet.Pilot.Labels.awaits_human()

  @type decision ::
          {:spawn, role :: String.t(), profile :: Fleet.CapProfile.t()} | {:skip, atom()}

  @doc """
  Décision pure : payload issue Gitea → `{:spawn, role, profile}` | `{:skip, reason}`.
  `load_role` (fun arité 1 → `{:ok, profile} | {:error, _}`) injectable pour les tests ; défaut =
  `CapProfile.load/1`. F075 : le profil chargé pour décider est THREADÉ dans `{:spawn, …}` et réutilisé
  au spawn par `dispatch_issue` (fin du double-load sonde+reload).
  """
  @spec decide(map(), (String.t() -> {:ok, Fleet.CapProfile.t()} | {:error, term()})) ::
          decision()
  def decide(payload, load_role \\ &default_load_role/1) when is_map(payload) do
    issue = Map.get(payload, "issue", payload)
    labels = Enum.map(Map.get(issue, "labels", []), & &1["name"])
    assignees = Map.get(issue, "assignees") || []

    cond do
      @in_flight_label in labels ->
        {:skip, :in_flight}

      # A2.3b : verrou HUMAIN (verdict gatekeeper escalate/halt/redirect, ou anomalie A2.6).
      # L'issue attend une action via l'arch ; le poller NE re-dispatche PAS (sinon, après
      # l'unlock de `await_human`, l'assignee=gatekeeper relancerait un jugement en boucle).
      @awaits_human_label in labels ->
        {:skip, :awaits_human}

      assignees == [] ->
        {:skip, :no_assignee}

      true ->
        # Forge-state-machine (DN §1) : un ticket assigné (à l'humain owner), non verrouillé → on
        # spawn le rôle PRODUCTEUR du catalogue. Il est INVARIANT (« seule cible des tickets code =
        # l'eng ») → `:producer_role` (config, défaut "engineer"), jamais un marqueur par-ticket.
        role = producer_role()

        # F075 : on charge le cap-profile UNE fois ici (la décision EN dépend) et on le threade —
        # `dispatch_issue` le réutilise au spawn au lieu de recharger. load-error → :no_role.
        with {:ok, profile} <- load_role.(role) do
          {:spawn, role, profile}
        else
          _ -> {:skip, :no_role}
        end
    end
  end

  # Rôle producteur (DN §1, invariant) : `:producer_role` (config, data catalogue), défaut "engineer".
  @default_producer_role "engineer"
  defp producer_role,
    do: Application.get_env(:fleet_pilot, :producer_role, @default_producer_role)

  @doc """
  Dispatch effectif d'une issue : `decide/2` puis, sur `{:spawn, role, profile}`, l'ordre
  canonique du spawn (verrou → comment → pod). Idempotent via les write-ops ForgeClient.

  `opts` : `:repo` (obligatoire), `:forge_opts` (passé au ForgeClient), + seams
  `:forge_client` / `:loader` / `:spawner` / `:clock` (défauts = modules réels).
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

    case decide(payload, &loader.load/1) do
      {:skip, reason} ->
        {:skipped, reason}

      {:spawn, role0, profile0} ->
        issue = Map.get(payload, "issue", payload)
        number = issue["number"]
        repo = Keyword.fetch!(opts, :repo)
        forge_opts = Keyword.get(opts, :forge_opts, [])

        # PROJET résolu AVANT toute écriture forge (read-only ls-remote) : un échec
        # transitoire ne laisse pas de verrou orphelin. base_sha pinné HORS-pod (F-03 R1,
        # symétrique de l'Executor) → injecté au clone du pod (project.base_sha).
        # PROJET + ROUTE résolus AVANT toute écriture forge (read-only) : un échec transitoire
        # ne laisse pas de verrou orphelin. project = base_sha pinné (F-03) ; route = (pipeline,
        # stage) gravé sur la forge (A2.1) → identifie le stage (l'assignee=rôle ne suffit pas).
        # `:none` (hors-carte / 1-stage) → route nil → comportement A1.
        # F075 : le cap-profile est chargé par `decide` (threadé dans `{:spawn, role, profile}`) AVANT
        # toute écriture forge — un échec de load = `{:skip, :no_role}` (zéro verrou orphelin). `mandate_kind`
        # (F077) en dépend ; plus de reload ici (fin du double-load sonde+spawn).
        with {:ok, project} <- tag_err(resolver.(repo, opts), :project_resolution),
             {:ok, route} <-
               tag_err(route_for(forge, repo, number, forge_opts), :route_resolution),
             # #8 (carte-driven) : le rôle à spawner dérive de la POSITION carte (route gravée), PAS de
             # `producer_role` en dur. Amende l'invariant DN §1 « issue→producteur toujours » → « issue→
             # rôle du stage courant de la carte ». route=nil (hors-carte / A1) → producteur de `decide`
             # (role0/profile0) : comportement BYTE-IDENTIQUE, le flux prouvé ne bouge pas tant qu'aucune
             # carte n'est posée. route={pipeline,stage} → `CarteNav.stage_role`. Échec de résolution sur
             # une issue ROUTÉE = misconfig → fail-loud (jamais un fallback eng muet : un stage
             # `mandate-review` qui retomberait sur l'eng = la gate sautée en silence).
             {:ok, {role, profile, stage_spec}} <-
               tag_err(
                 carte_role(route, role0, profile0, &loader.load/1, carte_loader),
                 :role_resolution
               ) do
          # BL-055 : pod_id DÉTERMINISTE STABLE keyé sur (issue, rôle) — PLUS de `-<ts>`. Le timestamp
          # rendait l'id unique par hop → re-spawn à chaque rework, l'eng pipe (long-lived) lingérait,
          # contexte perdu. Stable → un re-dispatch retombe sur le MÊME pod : s'il est vivant (eng pipe),
          # on le RE-MANDATE (garde son contexte), sinon on spawn. (Idempotence — cf. spawn_or_remandate.)
          # F071 : le préfixe "issue-" ci-dessous (et la branch hop_consumer.ex:318 "lcars/issue-...") est
          # aligné PAR CONVENTION sur `Fleet.Pilot.TicketId.@prefix` — formats DISTINCTS du ticket_id (jamais
          # parsés), mais si ce préfixe change un jour, mettre à jour ces 2 littéraux aussi (couplage implicite).
          pod_id = "issue-#{number}-#{role}"

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
              pod_id: pod_id
            ]
            |> maybe_put_project(project)
            |> maybe_put_route(route)

          # BL-055 : eng pipe déjà vivant (id stable) ? → RE-MANDATE (garde le contexte), sinon spawn.
          alive_before? = pod_alive?(spawner, pod_id)

          # Ordre canonique du SPAWN (DN §6) : label-verrou AVANT pod. Le verrou = le LABEL
          # `lcars-in-flight` (mutex machine-state) ; PAS de comment-lock dans le ticket (écriture
          # morte, jamais lue — retirée : le ticket garde du contenu humain ; recovery = liveness pod).
          with {:ok, _} <- forge.add_label(repo, number, @in_flight_label, forge_opts),
               {:ok, _} <-
                 maybe_spawn(
                   spawner,
                   alive_before?,
                   profile,
                   Fleet.Pilot.TicketId.compose(number),
                   spawn_opts
                 ),
               :ok <- enqueue_mandate(task_queue, pod_id, role, number, mandate) do
            # Wake + recovery (#5.2) : re-roll (re-spawn worker) au 1er fail, escalade système au 2e.
            _ =
              Fleet.Pilot.WakeRecovery.wake(
                pod_id,
                fn ->
                  maybe_spawn(
                    spawner,
                    false,
                    profile,
                    Fleet.Pilot.TicketId.compose(number),
                    spawn_opts
                  )
                end,
                wake_fun: fn p -> safe_wake(spawner, p) end
              )

            Logger.info(
              "StageDispatcher: #{disposition(alive_before?)} role=#{role} pod=#{pod_id} issue=#{repo}##{number} " <>
                "project=#{if(project, do: project["base_sha"], else: "none")} route=#{inspect(route)}"
            )

            {:ok, {:spawned, pod_id, role}}
          else
            {:error, _} = err ->
              # F181 : une étape POST-verrou a échoué. Compensation : retrait du verrou (sinon le poller
              # SKIP l'issue à jamais). Kill **seulement si on a FRAÎCHEMENT spawné** — un re-mandate ne
              # doit JAMAIS tuer l'eng vivant + son contexte sur un échec d'enqueue (BL-055). Le prochain
              # tick re-dispatche proprement.
              if not alive_before?, do: safe_kill(spawner, pod_id)
              _ = forge.remove_label(repo, number, @in_flight_label, forge_opts)

              Logger.warning(
                "StageDispatcher: dispatch role=#{role} issue=#{repo}##{number} → #{inspect(err)} " <>
                  "(verrou retiré#{if(not alive_before?, do: ", pod tué", else: "")} — re-dispatch au prochain tick)"
              )

              err
          end
        else
          {:error, {phase, reason}} ->
            Logger.warning(
              "StageDispatcher: #{phase} role=#{role0} issue=#{repo}##{number} → #{inspect(reason)} (skip, pas de verrou)"
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
      opts: opts
    }

    pr_number = pr["number"]
    head = get_in(pr, ["head", "ref"]) || ""
    head_sha = get_in(pr, ["head", "sha"])
    labels = Enum.map(Map.get(pr, "labels") || [], & &1["name"])

    # Le SET des juges = `requested_reviewers` (posé par `request_review` ; carte ET no-carte), logins
    # downcasés. Gitea NE LES RETIRE PAS de façon fiable après review (vérifié live #6) → on n'en déduit
    # PAS « qui reste à juger ». C'est la LISTE DES REVIEWS (verdict décisif par juge) qui le dit.
    requested = pr |> Map.get("requested_reviewers") |> List.wrap() |> Enum.map(&login_of/1)

    if @in_flight_label in labels do
      {:skipped, :in_flight}
    else
      # head_sha → verdicts COMMIT-SCOPÉS : une review sur un commit antérieur (REQUEST_CHANGES jamais
      # dismissé par Gitea au push) est PÉRIMÉE → son juge redevient `pending` → re-dispatché sur le code
      # courant (sinon rework infini, live #7).
      verdict_opts = Keyword.put(ctx.forge_opts, :head_sha, head_sha)

      case ctx.forge.pr_review_verdicts(ctx.repo, pr_number, verdict_opts) do
        {:ok, verdicts} ->
          dispatch_by_verdicts(requested, verdicts, pr_number, head, ctx)

        {:error, reason} ->
          {:error, {:review_state, reason}}
      end
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
        promote_pr(pr_number, head, ctx)
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
    %{
      repo: repo,
      forge: forge,
      spawner: spawner,
      task_queue: task_queue,
      resolver: resolver,
      forge_opts: forge_opts,
      opts: opts
    } = ctx

    # ②.1d — le pod review (juge) OU rework (producteur) clone la FEATURE-BRANCH (`head.ref`), PAS
    # `main` : le juge doit voir le DIFF du producteur (sinon il juge `main`, c.-à-d. rien de réel) ;
    # le rework reprend SON propre travail. Read-only sur le code via le workspace provisionné par le
    # système (barrière §4 préservée : zéro token forge au pod). `base_branch: head` → base_sha = tip
    # de la feature-branch.
    review_opts = Keyword.put(opts, :base_branch, head)

    # PROJET + ROUTE resolus AVANT toute ecriture forge (read-only) : un echec ne laisse pas de
    # verrou orphelin. La route (pipeline, stage) est lue sur l'ISSUE (le pipeline-state y reste).
    with {:ok, project} <- tag_err(resolver.(repo, review_opts), :project_resolution),
         {:ok, route} <- tag_err(route_for(forge, repo, issue_n, forge_opts), :route_resolution) do
      # BL-055 : id déterministe stable. Le REWORK (producteur) keye sur l'ISSUE → MÊME id que
      # dispatch_issue → retombe sur l'eng pipe vivant pour le RE-MANDATER (garde son contexte de
      # diagnostic across reworks). Le JUGE (one-shot) keye sur la PR → re-spawn frais à chaque review.
      pod_id =
        case kind do
          :rework -> "issue-#{issue_n}-#{role}"
          _ -> "pr-#{pr_number}-#{role}"
        end

      # :judge -> GateBrief desamorce (I-CBC) ; :rework -> brief de rework au PRODUCTEUR (corrige + push).
      mandate =
        review_mandate(kind, profile, role, forge, repo, issue_n, forge_opts, route, pr_number)

      spawn_opts =
        [mandate: mandate, pod_id: pod_id]
        |> maybe_put_project(project)
        |> maybe_put_route(route)

      # BL-055 : eng pipe déjà vivant (rework, id stable) ? → re-mandate, sinon spawn.
      alive_before? = pod_alive?(spawner, pod_id)

      # Ordre canonique du spawn (label-verrou AVANT pod). Verrou = LABEL `lcars-in-flight` sur la PR
      # (pr_number, pas l'issue) ; pas de comment-lock (écriture morte, retirée — cf. dispatch_issue).
      with {:ok, _} <- forge.add_label(repo, pr_number, @in_flight_label, forge_opts),
           {:ok, _} <-
             maybe_spawn(
               spawner,
               alive_before?,
               profile,
               Fleet.Pilot.TicketId.compose(issue_n),
               spawn_opts
             ),
           :ok <- enqueue_mandate(task_queue, pod_id, role, issue_n, mandate) do
        # Wake + recovery (#5.2) : re-roll (re-spawn worker) au 1er fail, escalade système au 2e.
        _ =
          Fleet.Pilot.WakeRecovery.wake(
            pod_id,
            fn ->
              maybe_spawn(
                spawner,
                false,
                profile,
                Fleet.Pilot.TicketId.compose(issue_n),
                spawn_opts
              )
            end,
            wake_fun: fn p -> safe_wake(spawner, p) end
          )

        Logger.info(
          "StageDispatcher: review-#{disposition(alive_before?)} role=#{role} pod=#{pod_id} pr=#{repo}##{pr_number} issue=##{issue_n}"
        )

        {:ok, {:spawned, pod_id, role}}
      else
        {:error, _} = err ->
          # F181 (jumeau dispatch_issue) : compense (retrait verrou PR) pour ne pas stuck la PR.
          # Kill SEULEMENT si frais spawn — un re-mandate ne tue pas l'eng vivant + son contexte (BL-055).
          if not alive_before?, do: safe_kill(spawner, pod_id)
          _ = forge.remove_label(repo, pr_number, @in_flight_label, forge_opts)

          Logger.warning(
            "StageDispatcher: review-dispatch role=#{role} pr=#{repo}##{pr_number} → #{inspect(err)} " <>
              "(verrou retiré#{if(not alive_before?, do: ", pod tué", else: "")})"
          )

          err
      end
    else
      {:error, {phase, reason}} ->
        Logger.warning(
          "StageDispatcher: #{phase} review role=#{role} pr=#{repo}##{pr_number} → #{inspect(reason)} (skip, pas de verrou)"
        )

        {:error, {phase, reason}}
    end
  end

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
          _ = safe_kill(ctx.spawner, "issue-#{issue_n}-#{producer}")

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

  defp maybe_put_project(spawn_opts, nil), do: spawn_opts
  defp maybe_put_project(spawn_opts, project), do: Keyword.put(spawn_opts, :project, project)

  defp maybe_put_route(spawn_opts, nil), do: spawn_opts

  defp maybe_put_route(spawn_opts, {pipeline, stage}),
    do: spawn_opts |> Keyword.put(:pipeline, pipeline) |> Keyword.put(:stage, stage)

  # Mandat d'un dispatch PR (Corr.3 4-C) : :judge -> GateBrief desamorce (via build_mandate, le pod
  # juge l'issue) ; :rework -> brief de rework au PRODUCTEUR (corrige selon la review, re-pousse).
  # #8.B/#8.E : chemin PR-juge — pas de stage carte ici (juges PR-driven) → `stage_spec = %{}` :
  # build_mandate retombe sur le `mandate_kind` du profil (judge pour qualifier/reviewer) ET sur le
  # `judge_target` par défaut (deliverable) → build_judge_mandate (juge le livrable/PR). Inchangé.
  defp review_mandate(:judge, profile, role, forge, repo, issue_n, forge_opts, route, _pr),
    do: build_mandate(profile, role, forge, repo, issue_n, %{}, forge_opts, route, %{})

  defp review_mandate(:rework, _profile, role, forge, repo, _issue_n, forge_opts, route, pr),
    do: rework_mandate(role, forge, repo, pr, forge_opts, route)

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
        build_mandate_review_mandate(role, forge, repo, number, forge_opts, route)

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
  defp build_mandate_review_mandate(role, forge, repo, number, forge_opts, route) do
    mandat =
      case forge.get_issue(repo, number, forge_opts) do
        {:ok, issue} -> Map.get(issue, "body") || ""
        _ -> ""
      end

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

  # Tag l'erreur d'une étape de résolution (préserve {:project_resolution, _} attendu).
  defp tag_err({:ok, _} = ok, _tag), do: ok
  defp tag_err({:error, reason}, tag), do: {:error, {tag, reason}}

  # #8 (carte-driven role) : dérive `{role, profile}` de la POSITION carte. route=nil → producteur de
  # `decide` (rétro-compat A1, exact). route={pipeline,stage} → `CarteNav.stage_role` + load du profil.
  # Issue routée dont la carte/stage/profil ne résout pas = misconfig → `{:error,...}` (fail-loud).
  @spec carte_role(
          {String.t(), String.t()} | nil,
          String.t(),
          Fleet.CapProfile.t(),
          (String.t() -> {:ok, Fleet.CapProfile.t()} | {:error, term()}),
          (String.t() -> map())
        ) :: {:ok, {String.t(), Fleet.CapProfile.t(), map()}} | {:error, term()}
  defp carte_role(nil, producer_role, producer_profile, _load_role, _carte_loader),
    do: {:ok, {producer_role, producer_profile, %{}}}

  defp carte_role({pipeline, stage}, _producer_role, _producer_profile, load_role, carte_loader) do
    with {:ok, carte} <- load_carte(pipeline, carte_loader),
         {:ok, role} <- carte_stage_role(carte, pipeline, stage),
         {:ok, profile} <- load_role.(role) do
      # #8.B/#8.E : on remonte le STAGE_SPEC entier (extensible) plutôt qu'un champ isolé. build_mandate y
      # lit `mandate_kind` (#8.B — override per-stage : consultant worker → juge sans profil-doublon) ET
      # `judge_target` (#8.E — juge le MANDAT vs un livrable). route=nil (producteur A1) → stage_spec vide.
      stage_spec = get_in(carte, ["stages", stage]) || %{}
      {:ok, {role, profile, stage_spec}}
    end
  end

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

  # ============================================================
  # Internals
  # ============================================================

  defp default_load_role(role), do: Fleet.CapProfile.load(role)

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

    case forge_base_url(forge_opts) do
      nil ->
        {:ok, nil}

      base_url ->
        repo_url = "#{String.trim_trailing(base_url, "/")}/#{repo}.git"

        case ls_remote_sha(repo_url, base_branch) do
          {:ok, sha} ->
            {:ok, %{"repo_path" => repo_url, "base_branch" => base_branch, "base_sha" => sha}}

          {:error, _} = err ->
            err
        end
    end
  end

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
