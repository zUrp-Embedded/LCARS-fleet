defmodule Fleet.Pilot.StepDispatcher do
  @moduledoc """
  Dispatch `issue assigné → spawn le rôle de la workflow_map` : la forge EST la machine à états, ce module
  réagit à ses transitions. Le poller voit un issue **assigné-à-moi** (scoping multi-user porté
  forge-side, en amont), non verrouillé, et le pousse à son step courant.

  ## Décision (`decide/1`) — PORTE pure

  À partir du payload d'une issue Gitea : `:engage` (procéder) | `{:skip, reason}` (`:in_flight` verrou posé,
  `:awaits_arch` verrou humain). decide ne fait QUE la porte — pas d'ownership (scoping forge-side amont),
  pas de rôle ni de load (le RÔLE vient de la POSITION workflow_map, via `workflow_map_role` ; voir Effets).

  ## Effets (`dispatch_issue/2`)

  Sur `:engage` : résout projet + route, puis :
    * **route absente** (issue routeless — create_issue ne grave plus, ou issue humain brut) →
      `ensure_workflow_map_or_onboard` grave la **workflow_map par défaut** (brief-gate) → `{:skipped, :onboarded}`
      (on défère ; le tick suivant la voit routée). C'est l'ENTRÉE système : create_issue crée, le poller route.
    * **route présente** → `workflow_map_role` dérive `{role, profile, step_spec}` de la POSITION workflow_map (PAS de
      producteur en dur — la route décide ; route absente à ce point = anomalie → fail-loud, jamais l'eng en
      silence), puis l'**ordre canonique du spawn** (label `lcars-in-flight` AVANT pod, sinon double-spawn).

  Les juges sont dispatchés PR-driven via `dispatch_review/2` (requested_reviewers) : le gate PR + la
  lecture de `pr_review_state` restent ici, tout l'aiguillage (verdicts / rework / conflit / promotion) est
  délégué à `Fleet.Pilot.StepDispatcher.ReviewLifecycle`. Les modules
  `:forge_client` / `:loader` / `:workflow_map_loader` / `:spawner` sont des **seams** (défauts = modules réels).
  """

  require Logger

  # Autorité du FORMAT des briefs (worker/judge/brief-review/rework/conflit). StepDispatcher
  # CHOISIT quel brief selon l'état forge ; BriefBuilder le FORME.
  alias Fleet.Pilot.BriefBuilder

  # Source unique de l'idiome « pose la clé SI non-nil » (builders de spawn_opts).
  alias Fleet.Pilot.Opts

  # Cycle de vie REVIEW (PR) extrait : `dispatch_review/2` (ci-dessous, contrat poller) fait le gate PR +
  # lit `pr_review_state`, PUIS délègue tout l'aiguillage (verdicts / rework / conflit / promotion) à
  # `ReviewLifecycle.dispatch_by_verdicts/5`. Dépendance uni-directionnelle (cœur → ReviewLifecycle →
  # Spawn/ArchEscalation → ø). `route_for/4` + `tag_err/2` restent ICI (partagés avec `dispatch_issue`) et
  # sont threadés à ReviewLifecycle par CAPTURE dans le `%ReviewLifecycle.Ctx{}` — pas de fork, pas de cycle.
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle

  # Feuille de spawn SINGLE-AUTHORITY extraite : les DEUX flux (issue + review) CONVERGENT sur
  # `Spawn.spawn_step/9` (ordre verrou→pod→enqueue→wake + compensation + contrat `wake_unreached`),
  # `Spawn.pod_id_for_scope/4` (identité pod) et `Spawn.serialize_project_scope/6` (gate scope) — une
  # seule copie chacun, jamais un fork. Le cœur DÉCIDE (route/rôle/verdict), Spawn EXÉCUTE.
  alias Fleet.Pilot.StepDispatcher.Spawn

  # Builders d'opts / naming du spawn (rc_name / feature_slug / maybe_put_route / resolve_repo_id) —
  # partagés avec le flux review (RoleDispatch), une seule copie.
  alias Fleet.Pilot.StepDispatcher.Spawn.Naming

  # Vocabulaire protocole = source unique Fleet.Pilot.Labels (constantes compile-time).
  @in_flight_label Fleet.Pilot.Labels.in_flight()
  @awaits_arch_label Fleet.Pilot.Labels.awaits_arch()

  @type decision :: :engage | {:skip, atom()}

  @doc """
  Décision PURE (porte) : payload issue → `:engage` | `{:skip, reason}`. decide ne fait QUE la
  porte : verrou `lcars-in-flight` / `lcars-awaits-arch` → skip ; sinon → `:engage` (proceder). Le rôle ET
  l'action (spawn vs onboard) sont décidés EN AVAL (`dispatch_issue`) — d'où `:engage` et pas `:spawn`. Le SCOPING
  (forge-side, en amont) et le ROUTAGE (route → rôle, via `workflow_map_role`/onboard dans `dispatch_issue`) ne
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
  (routeless → grave la workflow_map par défaut → skip), soit dérive le rôle de la workflow_map (`workflow_map_role`) et
  applique l'ordre canonique du spawn (verrou → pod → enqueue → wake, `spawn_step`). Idempotent.

  `opts` : `:repo` (obligatoire), `:forge_opts` (passé au ForgeClient), + seams
  `:forge_client` / `:loader` / `:workflow_map_loader` / `:spawner` / `:task_queue` (défauts = modules réels).
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

    # Chargeur de workflow_map injectable (seam, comme les autres) — rend `workflow_map_role` testable sans disque.
    workflow_map_loader = Keyword.get(opts, :workflow_map_loader, &Fleet.Workflow.Loader.load!/1)

    case decide(payload) do
      {:skip, reason} ->
        {:skipped, reason}

      :engage ->
        issue = Map.get(payload, "issue", payload)
        number = issue["number"]
        repo = Keyword.fetch!(opts, :repo)
        forge_opts = Keyword.get(opts, :forge_opts, [])

        # PROJET + ROUTE résolus AVANT toute écriture forge (read-only) : un échec transitoire ne laisse pas
        # de verrou orphelin. project = base_sha pinné (hors-pod) ; route = (workflow_map_name, step) gravée forge-side.
        # ROUTELESS = pas encore onboardée (create_issue ne grave plus) → `ensure_workflow_map_or_onboard`
        # grave la workflow_map par défaut + renvoie `{:onboarded, _}` → on DÉFÈRE (skip ; le tick suivant la voit
        # routée). Routée → `workflow_map_role` dérive le rôle de la POSITION workflow_map (PAS de producteur en dur ;
        # route absente à ce point = anomalie post-onboard → fail-loud, JAMAIS l'eng en silence).
        # Route + workflow_map pré-lues par le poller (classification du bail) → réutilisées via opts
        # (`resolve_route` / `:prefetched_workflow_map`) au lieu d'un 2ᵉ get_route + 2ᵉ load workflow_map. Absentes (tests,
        # autres callers) → lecture/chargement normaux (fallback).
        with {:ok, project} <- tag_err(resolver.(repo, opts), :project_resolution),
             {:ok, route} <-
               tag_err(resolve_route(opts, forge, repo, number, forge_opts), :route_resolution),
             {:ok, route} <-
               ensure_workflow_map_or_onboard(
                 forge,
                 repo,
                 number,
                 route,
                 workflow_map_loader,
                 forge_opts
               ),
             {:ok, {role, profile, step_spec}} <-
               tag_err(
                 workflow_map_role(
                   route,
                   &loader.load/1,
                   workflow_map_loader,
                   Keyword.get(opts, :prefetched_workflow_map)
                 ),
                 :role_resolution
               ),
             # Identité du pod + sérialisation LUES du catalogue (`slot_scope`), jamais devinées :
             # `pod_id_for_scope/4` (instance → for_issue, fan-out par issue | project → for_repo, UNE
             # identité par projet) et `serialize_project_scope/3` (gate AVANT tout verrou : un rôle
             # project-scoped déjà vivant → on défère `{:skipped, :role_busy}`, sinon on verrouillerait
             # une issue qu'on ne traite pas ; le poller re-dispatch au tick suivant).
             scope = Fleet.CapProfile.slot_scope(profile),
             pod_id = Spawn.pod_id_for_scope(scope, repo, number, role),
             slug = Naming.feature_slug(issue),
             :ok <-
               Spawn.serialize_project_scope(
                 scope,
                 Fleet.CapProfile.lifetime_scope(profile),
                 spawner,
                 pod_id,
                 project,
                 slug
               ) do
          # pod_id et branche (`lcars/issue-N-role`) construits indépendamment depuis (n, role) ; pod_id
          # opaque (jamais re-parsé). La branche reste repo-LOCALE (pas de collision intra-repo).

          # La FORME du brief (worker exécutable | juge désamorcé) est lue du cap-profile
          # (`brief_kind`), PAS d'un nom magique "gatekeeper" en ring2 (differentiation-par-catalogue).
          # Calculé UNE fois → sert au spawn-file ET au brief TaskQueue (que le pod pull via get_work_item).
          # Sans ça, enqueue_brief ré-enqueuerait `issue["body"]` brut → un juge pullerait le brief BUILD
          # exécutable au lieu du GateBrief.
          brief =
            BriefBuilder.build_brief(
              profile,
              role,
              forge,
              repo,
              number,
              issue,
              forge_opts,
              route,
              step_spec
            )

          spawn_opts =
            [
              brief: brief,
              pod_id: pod_id,
              rc_name: Naming.rc_name(repo, role),
              # Nom de branche LOCALE parlant (titre du issue sanitizé), pas
              # le pod_id. Sert à phase.ex → `feature/<slug>`. Calculé une fois (réutilisé par le gate
              # pour la reprovision in-place d'un pipe : même branche au reset qu'au spawn).
              slug: slug
            ]
            |> Opts.maybe_put(:project, project)
            |> Naming.maybe_put_route(route)
            |> Opts.maybe_put(:repo_id, Naming.resolve_repo_id(forge, repo, forge_opts))

          # Spawn LEAF partagé avec dispatch_by_verdicts (verrou → pod → enqueue → wake +
          # compensation). Producteur : verrou + issue_id keyés sur l'ISSUE (number). On construit le
          # struct de seams à ce site (les 6 seams, pas le `opts` entier — frontière blindée).
          log_ctx =
            "issue=#{repo}##{number} " <>
              "project=#{if(project, do: project["base_sha"], else: "none")} route=#{inspect(route)}"

          Spawn.spawn_step(
            %Spawn.Seams{
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
            brief,
            spawn_opts,
            number,
            number,
            log_ctx
          )
        else
          {:skipped, :role_busy} ->
            # Rôle project-scoped déjà occupé par un autre issue du repo → DÉFÉRÉ sans verrou ni
            # enqueue ; le poller re-dispatch au tick suivant (sérialisation par-(repo,rôle) via la
            # boucle de poll ; le pod one-shot meurt en fin de tâche → spawn frais pour le suivant).
            {:skipped, :role_busy}

          {:onboarded, _step} ->
            # Issue routeless onboardée sur la workflow_map par défaut → on DÉFÈRE (skip ; le tick suivant
            # la voit routée → dispatch). Entrée système : create_issue crée, le poller route.
            {:skipped, :onboarded}

          {:error, {phase, reason}} ->
            Logger.warning(
              "StepDispatcher: #{phase} issue=#{repo}##{number} → #{inspect(reason)} (skip, pas de verrou)"
            )

            {:error, {phase, reason}}
        end
    end
  end

  @doc """
  Dispatch PR-driven d'un JUGE (switch review-request). Une PR ouverte avec une review
  demandee (`requested_reviewers`) -> spawn le role juge pour la reviewer. Remplace le trigger
  assignee-issue pour les JUGES (le producteur reste issue-assignee-driven, via `dispatch_issue`).

  Le pipeline-state (route = position workflow_map) reste sur l'ISSUE : `dispatch_review` remonte de
  `head.ref` (`lcars/issue-N-role`) au issue et lit la route gravee. Le verrou `lcars-in-flight`
  est pose sur la PR (pas l'issue) : il empeche le re-spawn du juge entre le spawn et la review
  postee (apres quoi Gitea retire le reviewer de `requested_reviewers`). Idempotent (verrou PR +
  dedup du lock comment).

  Le gate PR (in-flight / awaits-arch) + la construction du `ctx` + la lecture de `pr_review_state`
  vivent ICI ; l'aiguillage (verdicts / rework / conflit / promotion) est DÉLÉGUÉ à
  `ReviewLifecycle.dispatch_by_verdicts/5`.

  `pr` : map Gitea (`number`, `head.ref`, `requested_reviewers`, `labels`). `opts` comme
  `dispatch_issue/2`. Returns `{:ok, {:spawned, pod_id, role}}` | `{:skipped, reason}` | `{:error, _}`.
  """
  @spec dispatch_review(map(), keyword()) ::
          {:ok, {:spawned, String.t(), String.t()}} | {:skipped, atom()} | {:error, term()}
  def dispatch_review(pr, opts) when is_map(pr) do
    # Contexte complet du flux review, construit à ce site UNIQUE et threadé à ReviewLifecycle. Struct
    # blindé `%ReviewLifecycle.Ctx{}` (pas une map nue) : `@enforce_keys` force chaque champ, un accès
    # `ctx.<typo>` ne compile pas. `route_reader`/`err_tagger` = captures des helpers du cœur
    # (`route_for/4`/`tag_err/2`, partagés avec `dispatch_issue`) — comme `resolver`/`wake_recovery`, la
    # capture est créée ICI → ReviewLifecycle ne référence jamais ce module (uni-directionnel, pas de cycle).
    ctx = %ReviewLifecycle.Ctx{
      forge: Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient),
      loader: Keyword.get(opts, :loader, Fleet.CapProfile),
      workflow_map_loader: Keyword.get(opts, :workflow_map_loader, &Fleet.Workflow.Loader.load!/1),
      spawner: Keyword.get(opts, :spawner, Fleet.Spawner),
      task_queue: Keyword.get(opts, :task_queue, Fleet.TaskQueue),
      resolver: Keyword.get(opts, :project_resolver, &default_project_resolver/2),
      repo: Keyword.fetch!(opts, :repo),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      # Seam de recovery de wake (défaut = la vraie fn) threadé depuis opts.
      wake_recovery: Keyword.get(opts, :wake_recovery, &Fleet.Pilot.WakeRecovery.wake/3),
      opts: opts,
      route_reader: &route_for/4,
      err_tagger: &tag_err/2
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
            ReviewLifecycle.dispatch_by_verdicts(requested, verdicts, pr_number, head, ctx)

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

    case Fleet.Pilot.ForgeProtocol.parse_feature_branch(head) do
      {:ok, {n, _role}} -> MapSet.member?(ids, n)
      :error -> false
    end
  end

  defp login_of(r), do: r |> Map.get("login", "") |> to_string() |> String.downcase()

  # Tag l'erreur d'une étape de résolution (préserve {:project_resolution, _} attendu). PARTAGÉ par les
  # deux flux : appelé en direct par `dispatch_issue` (issue) ET threadé par capture (`err_tagger`) vers
  # `ReviewLifecycle` (review) — une seule copie, pas de fork, pas de référence remontante (pas de cycle).
  defp tag_err({:ok, _} = ok, _tag), do: ok
  defp tag_err({:error, reason}, tag), do: {:error, {tag, reason}}

  # WorkflowMap-driven role : dérive `{role, profile, step_spec}` de la POSITION workflow_map (route gravée) +
  # load du profil. route nil = anomalie → fail-loud (pas de fallback producteur). WorkflowMap/step/
  # profil non résolus = misconfig → `{:error, _}` (fail-loud).
  # `prefetched_workflow_map` : workflow_map déjà chargée par le poller (classification du bail) → on évite un
  # 2ᵉ load ; `nil` (tests, autres callers) → chargement via `workflow_map_loader` (fallback).
  @spec workflow_map_role(
          {String.t(), String.t()} | nil,
          (String.t() -> {:ok, Fleet.CapProfile.t()} | {:error, term()}),
          (String.t() -> map()),
          map() | nil
        ) :: {:ok, {String.t(), Fleet.CapProfile.t(), map()}} | {:error, term()}
  # Route nil = ANOMALIE : le poller onboarde tout routeless AVANT dispatch (ensure_workflow_map_or_onboard)
  # → si on arrive ici sans route, fail-loud, JAMAIS un fallback eng silencieux. Le rôle vient TOUJOURS de la
  # position workflow_map (route gravée).
  defp workflow_map_role(nil, _load_role, _workflow_map_loader, _prefetched_workflow_map),
    do: {:error, :unrouted}

  defp workflow_map_role(
         {workflow_map_name, step},
         load_role,
         workflow_map_loader,
         prefetched_workflow_map
       ) do
    with {:ok, workflow_map} <-
           workflow_map_or_load(prefetched_workflow_map, workflow_map_name, workflow_map_loader),
         {:ok, role} <- workflow_map_step_role(workflow_map, workflow_map_name, step),
         {:ok, profile} <- load_role.(role) do
      # On remonte le STEP_SPEC entier (extensible) plutôt qu'un champ isolé. build_brief y
      # lit `brief_kind` (override per-step : consultant worker → juge sans profil-doublon) ET
      # `judge_target` (juge le BRIEF vs un livrable). route=nil (producteur initial) → step_spec vide.
      step_spec = get_in(workflow_map, ["steps", step]) || %{}
      {:ok, {role, profile, step_spec}}
    end
  end

  # WorkflowMap pré-chargée (poller) → réutilisée ; sinon chargée via le seam.
  defp workflow_map_or_load(nil, workflow_map_name, workflow_map_loader),
    do: load_workflow_map(workflow_map_name, workflow_map_loader)

  defp workflow_map_or_load(workflow_map, _pipeline, _workflow_map_loader),
    do: {:ok, workflow_map}

  # Route pré-lue par le poller (classification) → réutilisée ici ; absente → lecture forge.
  defp resolve_route(opts, forge, repo, number, forge_opts) do
    case Keyword.fetch(opts, :prefetched_route) do
      {:ok, route} -> {:ok, route}
      :error -> route_for(forge, repo, number, forge_opts)
    end
  end

  # Onboarding système. Route présente → passthrough `{:ok, route}`. Route nil (issue routeless :
  # create_issue ne grave plus la workflow_map ; ou issue humain brut) → grave la workflow_map par défaut (brief-gate)
  # = elle ENTRE dans le gate → `{:onboarded, step}` (dispatch_issue défère : skip ce tick, le suivant la
  # voit routée). Route postée par le SYSTÈME (forge token système). Échec → `{:error, {:onboard, _}}`.
  defp ensure_workflow_map_or_onboard(
         _forge,
         _repo,
         _number,
         route,
         _workflow_map_loader,
         _forge_opts
       )
       when not is_nil(route),
       do: {:ok, route}

  defp ensure_workflow_map_or_onboard(forge, repo, number, nil, workflow_map_loader, forge_opts) do
    workflow_map_name = default_workflow_map()

    with {:ok, workflow_map} <- load_workflow_map(workflow_map_name, workflow_map_loader),
         {:ok, {step, _role}} <- Fleet.Pilot.WorkflowMapNav.first_step(workflow_map),
         {:ok, _} <- forge.post_route(repo, number, workflow_map_name, step, forge_opts) do
      {:onboarded, step}
    else
      err -> {:error, {:onboard, err}}
    end
  end

  # WorkflowMap par défaut de l'onboarding (toute issue assignée routeless y entre ; défaut brief-gate : le
  # consultant review le brief AVANT l'eng). Data-catalogue, pas un nom magique en dur.
  defp default_workflow_map,
    do: Application.get_env(:fleet_pilot, :delegation_workflow_map, "brief-gate")

  # R4 : délégué à l'autorité unique (WorkflowMapNav.safe_load — même tag, plus de rescue local).
  defp load_workflow_map(workflow_map_name, workflow_map_loader),
    do: Fleet.Pilot.WorkflowMapNav.safe_load(workflow_map_loader, workflow_map_name)

  defp workflow_map_step_role(workflow_map, workflow_map_name, step) do
    case Fleet.Pilot.WorkflowMapNav.step_role(workflow_map, step) do
      {:ok, role} when is_binary(role) -> {:ok, role}
      _ -> {:error, {:workflow_map_step_unknown, workflow_map_name, step}}
    end
  end

  # Lit la position workflow_map (workflow_map_name, step) gravée sur la forge. `:none` (hors-workflow_map /
  # 1-step) → `{:ok, nil}` (producteur direct). Erreur HTTP → propagée (skip sans verrou). PARTAGÉ par les
  # deux flux : appelé en direct par `resolve_route` (issue) ET threadé par capture (`route_reader`) vers
  # `ReviewLifecycle` (review) — une seule copie, pas de fork, pas de référence remontante (pas de cycle).
  defp route_for(forge, repo, number, forge_opts) do
    case forge.get_route(repo, number, forge_opts) do
      {:ok, {_p, _s} = route} -> {:ok, route}
      :none -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================
  # Internals
  # ============================================================

  # Résolution projet (base_sha / gate_base_sha pinnés hors-pod via `git ls-remote`) extraite dans
  # `Fleet.Pilot.StepDispatcher.ProjectResolver` (cluster I/O isolé, quasi-pur). `default_project_resolver/2`
  # reste l'API PUBLIQUE de CE module (défaut du seam `:project_resolver` + appelée par les tests) →
  # `defdelegate` garde le contrat exact.
  defdelegate default_project_resolver(repo, opts), to: Fleet.Pilot.StepDispatcher.ProjectResolver
end
