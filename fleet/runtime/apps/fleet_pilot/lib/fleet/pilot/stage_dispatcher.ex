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
    1. PUT label `lcars-in-flight` (verrou)
    2. POST comment `[lock:<role>:<ts>]` (TTL / diagnostic recovery)
    3. spawn le pod avec le `profile` déjà chargé par `decide` (`Spawner.spawn_pod(profile,
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
    clock = Keyword.get(opts, :clock, &System.os_time/1)
    resolver = Keyword.get(opts, :project_resolver, &default_project_resolver/2)

    case decide(payload, &loader.load/1) do
      {:skip, reason} ->
        {:skipped, reason}

      {:spawn, role, profile} ->
        issue = Map.get(payload, "issue", payload)
        number = issue["number"]
        repo = Keyword.fetch!(opts, :repo)
        forge_opts = Keyword.get(opts, :forge_opts, [])
        ts = clock.(:second)

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
               tag_err(route_for(forge, repo, number, forge_opts), :route_resolution) do
          # pod_id DÉTERMINISTE (string connue AVANT spawn) : `Spawner.spawn_pod/3` retourne le
          # `pid` du GenServer ; on impose le pod_id via `:pod_id`. `ts` le rend unique par hop.
          # F071 : le préfixe "issue-" ci-dessous (et la branch hop_consumer.ex:318 "lcars/issue-...") est
          # aligné PAR CONVENTION sur `Fleet.Pilot.TicketId.@prefix` — formats DISTINCTS du ticket_id (jamais
          # parsés), mais si ce préfixe change un jour, mettre à jour ces 2 littéraux aussi (couplage implicite).
          pod_id = "issue-#{number}-#{role}-#{ts}"

          # F077/F078 : la FORME du mandat (worker exécutable | juge désamorcé) est lue du cap-profile
          # (`mandate_kind`), PAS d'un nom magique "gatekeeper" en ring2 (differentiation-par-catalogue).
          # Calculé UNE fois → sert au spawn-file ET au brief TaskQueue (que le pod pull via get_task).
          # Sans ça, enqueue_mandate ré-enqueuait `issue["body"]` brut → un juge pullait le mandat BUILD
          # exécutable au lieu du GateBrief → PASSE-9 recréé.
          mandate = build_mandate(profile, role, forge, repo, number, issue, forge_opts, route)

          spawn_opts =
            [
              mandate: mandate,
              pod_id: pod_id
            ]
            |> maybe_put_project(project)
            |> maybe_put_route(route)

          # Ordre canonique du SPAWN (DN §6) : label AVANT pod.
          with {:ok, _} <- forge.add_label(repo, number, @in_flight_label, forge_opts),
               {:ok, _} <-
                 forge.post_comment(
                   repo,
                   number,
                   "[lock:#{role}:#{ts}]",
                   Keyword.put(forge_opts, :dedup_signature, "[lock:#{role}:")
                 ),
               {:ok, _pid} <-
                 spawner.spawn_pod(profile, Fleet.Pilot.TicketId.compose(number), spawn_opts),
               :ok <- enqueue_mandate(task_queue, pod_id, role, number, mandate) do
            # Kick best-effort : le pod auto-kicke les workers ; le wake accélère le 1er get_task.
            _ = safe_wake(spawner, pod_id)

            Logger.info(
              "StageDispatcher: spawned role=#{role} pod=#{pod_id} issue=#{repo}##{number} " <>
                "project=#{if(project, do: project["base_sha"], else: "none")} route=#{inspect(route)}"
            )

            {:ok, {:spawned, pod_id, role}}
          else
            {:error, _} = err ->
              # F181 : une étape POST-verrou a échoué (post_comment / spawn / enqueue). Le verrou
              # `lcars-in-flight` est (peut-être) posé → sans compensation, le poller SKIP l'issue à
              # jamais (stuck). On compense : kill best-effort du pod (pod_id déterministe ; no-op s'il
              # n'a jamais spawné ou si enqueue a échoué pod-vivant → pas de pod orphelin), PUIS retrait
              # du verrou (best-effort) → le prochain tick re-dispatche proprement (pas de double-spawn :
              # plus de pod vivant). L'erreur est propagée (jamais d'avance silencieuse).
              _ = safe_kill(spawner, pod_id)
              _ = forge.remove_label(repo, number, @in_flight_label, forge_opts)

              Logger.warning(
                "StageDispatcher: spawn role=#{role} issue=#{repo}##{number} → #{inspect(err)} " <>
                  "(verrou retiré, pod tué — re-dispatch au prochain tick)"
              )

              err
          end
        else
          {:error, {phase, reason}} ->
            Logger.warning(
              "StageDispatcher: #{phase} role=#{role} issue=#{repo}##{number} → #{inspect(reason)} (skip, pas de verrou)"
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
    labels = Enum.map(Map.get(pr, "labels") || [], & &1["name"])
    reviewers = Map.get(pr, "requested_reviewers") || []

    cond do
      @in_flight_label in labels ->
        {:skipped, :in_flight}

      reviewers != [] ->
        # un juge est en attente -> on le spawn pour reviewer la PR.
        role = reviewers |> hd() |> Map.get("login", "") |> String.downcase()
        dispatch_pr_role(:judge, pr_number, head, role, ctx)

      true ->
        # pas de reviewer en attente : rework ? une review REQUEST_CHANGES courante => le PRODUCTEUR
        # (engineer) reprend pour corriger (4-C-iv). Sinon rien (PR approuvee en attente du merge).
        dispatch_rework(pr_number, head, ctx)
    end
  end

  # Rework juge : la PR porte un verdict REQUEST_CHANGES courant (review postee, plus de reviewer en
  # attente) -> le PRODUCTEUR (role git_native de head.ref) reprend pour corriger. Idempotent (verrou
  # PR). NB transitionnel : le mandat ne porte pas encore le feedback detaille de la review (4-C-iv+).
  defp dispatch_rework(pr_number, head, ctx) do
    case ctx.forge.pr_review_state(ctx.repo, pr_number, ctx.forge_opts) do
      {:ok, :changes_requested} ->
        case Fleet.Pilot.ForgeClient.parse_feature_branch(head) do
          {:ok, {_n, producer_role}} ->
            dispatch_pr_role(:rework, pr_number, head, producer_role, ctx)

          :error ->
            {:skipped, :not_fleet_branch}
        end

      {:ok, _} ->
        {:skipped, :no_work}

      {:error, reason} ->
        {:error, {:review_state, reason}}
    end
  end

  defp dispatch_pr_role(kind, pr_number, head, role, ctx) do
    with {:ok, {issue_n, _producer}} <- parse_feature_branch_or_skip(head),
         {:ok, profile} <- load_role_or_skip(ctx.loader, role) do
      do_dispatch_review(pr_number, issue_n, role, profile, kind, ctx)
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

  defp do_dispatch_review(pr_number, issue_n, role, profile, kind, ctx) do
    %{
      repo: repo,
      forge: forge,
      spawner: spawner,
      task_queue: task_queue,
      clock: clock,
      resolver: resolver,
      forge_opts: forge_opts,
      opts: opts
    } = ctx

    ts = clock.(:second)

    # PROJET + ROUTE resolus AVANT toute ecriture forge (read-only) : un echec ne laisse pas de
    # verrou orphelin. La route (pipeline, stage) est lue sur l'ISSUE (le pipeline-state y reste).
    with {:ok, project} <- tag_err(resolver.(repo, opts), :project_resolution),
         {:ok, route} <- tag_err(route_for(forge, repo, issue_n, forge_opts), :route_resolution) do
      pod_id = "pr-#{pr_number}-#{role}-#{ts}"

      # :judge -> GateBrief desamorce (I-CBC) ; :rework -> brief de rework au PRODUCTEUR (corrige + push).
      mandate =
        review_mandate(kind, profile, role, forge, repo, issue_n, forge_opts, route, pr_number)

      spawn_opts =
        [mandate: mandate, pod_id: pod_id]
        |> maybe_put_project(project)
        |> maybe_put_route(route)

      # Ordre canonique du spawn (label AVANT pod). Verrou sur la PR (pr_number), pas l'issue.
      with {:ok, _} <- forge.add_label(repo, pr_number, @in_flight_label, forge_opts),
           {:ok, _} <-
             forge.post_comment(
               repo,
               pr_number,
               "[lock:#{role}:#{ts}]",
               Keyword.put(forge_opts, :dedup_signature, "[lock:#{role}:")
             ),
           {:ok, _pid} <-
             spawner.spawn_pod(profile, Fleet.Pilot.TicketId.compose(issue_n), spawn_opts),
           :ok <- enqueue_mandate(task_queue, pod_id, role, issue_n, mandate) do
        _ = safe_wake(spawner, pod_id)

        Logger.info(
          "StageDispatcher: review-dispatch role=#{role} pod=#{pod_id} pr=#{repo}##{pr_number} issue=##{issue_n}"
        )

        {:ok, {:spawned, pod_id, role}}
      else
        {:error, _} = err ->
          # F181 (jumeau dispatch_issue) : une etape post-verrou a echoue -> compense (kill pod +
          # retrait verrou PR) pour ne pas stuck la PR a jamais.
          _ = safe_kill(spawner, pod_id)
          _ = forge.remove_label(repo, pr_number, @in_flight_label, forge_opts)

          Logger.warning(
            "StageDispatcher: review-dispatch role=#{role} pr=#{repo}##{pr_number} → #{inspect(err)} (verrou retire, pod tue)"
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

  defp maybe_put_project(spawn_opts, nil), do: spawn_opts
  defp maybe_put_project(spawn_opts, project), do: Keyword.put(spawn_opts, :project, project)

  defp maybe_put_route(spawn_opts, nil), do: spawn_opts

  defp maybe_put_route(spawn_opts, {pipeline, stage}),
    do: spawn_opts |> Keyword.put(:pipeline, pipeline) |> Keyword.put(:stage, stage)

  # Mandat d'un dispatch PR (Corr.3 4-C) : :judge -> GateBrief desamorce (via build_mandate, le pod
  # juge l'issue) ; :rework -> brief de rework au PRODUCTEUR (corrige selon la review, re-pousse).
  defp review_mandate(:judge, profile, role, forge, repo, issue_n, forge_opts, route, _pr),
    do: build_mandate(profile, role, forge, repo, issue_n, %{}, forge_opts, route)

  defp review_mandate(:rework, _profile, _role, _forge, _repo, _issue_n, _forge_opts, route, pr),
    do: rework_mandate(pr, route)

  # Brief de rework (4-C-iv) : le PRODUCTEUR (engineer) reprend sur une PR REQUEST_CHANGES.
  # Transitionnel : le feedback detaille de la review n'est pas encore injecte (le pod a la PR clonee
  # + voit son code ; enrichir le mandat avec le body de la review = raffinement ulterieur).
  defp rework_mandate(pr, route) do
    {pipeline, stage} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, nil}
      end

    "REWORK — une review REQUEST_CHANGES a ete deposee sur la PR ##{pr}. Corrige ton code selon le " <>
      "feedback de la review et re-pousse sur ta branche (meme PR). " <>
      "stage=#{stage || "?"} pipeline=#{pipeline || "?"}."
  end

  # F077 : la forme du mandat est une propriété du rôle (cap-profile `mandate_kind`), PAS un nom
  # magique en ring2. `judge` → GateBrief désamorcé ; tout le reste (`worker`, défaut) → corps d'issue.
  defp build_mandate(profile, role, forge, repo, number, issue, forge_opts, route) do
    case Fleet.CapProfile.mandate_kind(profile) do
      "judge" -> build_judge_mandate(role, forge, repo, number, forge_opts, route)
      _worker -> issue["body"] || ""
    end
  end

  # A2.3b item 5 (option B, DN gatekeeper-forge-encoding-v2 §5) : un pod **juge** doit savoir QUOI
  # juger ET comment rendre son verdict. On réutilise le brief canonique `Fleet.Pipeline.GateBrief`
  # (contexte + livrable + question + **contrat `gate-decision-v1.json` + options canon**) — le même
  # que le modèle RAM. Le `result_K` à juger est lu du comment du hop précédent (gravé par
  # HopCompleter, N-04) ; le pod reste forge-aveugle (le runtime lit le comment, option B, pas de
  # clone F-08).
  defp build_judge_mandate(role, forge, repo, number, forge_opts, route) do
    outputs =
      case forge.get_predecessor_result(repo, number, forge_opts) do
        {:ok, result} -> result
        _ -> %{}
      end

    {pipeline, stage} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, role}
      end

    # I-CBC (bug PASSE-9, prouvé live #11 ET #12) : le mandat du juge ne contient
    # AUCUNE instruction exécutable. Le body de l'issue (= mandat du BUILD :
    # « crée X, commit ») n'est PAS injecté — même quoté en contexte « NE PAS
    # exécuter », un pod base-worker (profile noop) l'exécute (il est amorcé pour
    # FAIRE) : sur #11 et #12 le gatekeeper a recommité SMOKE.md + soumis un
    # "status ok" sans `decision`. Le seul contexte fourni = les `outputs` du
    # prédécesseur (descriptifs : commit + summary, non-exécutables). Si un jour le
    # juge a une vraie persona, GateBrief sait rendre `request` en contexte
    # désamorcé — mais pas pour un base-worker.
    Fleet.Pipeline.GateBrief.build(%{
      stage: stage,
      pipeline_id: pipeline,
      gate: nil,
      outputs: outputs
    })
  end

  # Tag l'erreur d'une étape de résolution (préserve {:project_resolution, _} attendu).
  defp tag_err({:ok, _} = ok, _tag), do: ok
  defp tag_err({:error, reason}, tag), do: {:error, {tag, reason}}

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
