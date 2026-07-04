defmodule Fleet.Pilot.StepDispatcher.ReviewLifecycle do
  @moduledoc """
  Cycle de vie REVIEW (PR) extrait de `Fleet.Pilot.StepDispatcher`.

  `StepDispatcher.dispatch_review/2` (PUBLIQUE — contrat du poller) reste au cœur : elle fait le gate
  PR (`in-flight`/`awaits-arch`), lit `pr_review_state` (verdicts commit-scopés + jury stable) PUIS
  DÉLÈGUE ici tout l'aiguillage. Ce module porte l'AIGUILLAGE (`dispatch_by_verdicts/5`) + la
  PROMOTION scellée (`promote_pr`) ; les deux autres clusters du flux descendent en sous-modules :

    * `RoleDispatch` — feuille d'EXÉCUTION partagée : prépare et spawn UN rôle sur la PR
      (juge / rework / résolution). C'est la coupe qui rend le graphe acyclique : aiguillage ET
      remédiation convergent dessus (couper aiguillage↔rework en deux aurait créé un cycle).
    * `Remediation` — rework/conflit BORNÉS (budget forge-natif, IncidentRegistry) → au-delà,
      escalade arch, jamais de churn infini.

  La promotion reste ICI : son error-path (`{:error, {:merge, _}}` = conflit) ré-entre
  immédiatement dans l'aiguillage (fallback `Remediation.dispatch_conflict_resolution`) — le couple
  merge/conflit se lit d'un seul tenant au niveau de la décision.

  ## Dépendance UNI-directionnelle (pas de cycle)

  ReviewLifecycle → `RoleDispatch`/`Remediation` → `Spawn` (feuille de spawn SINGLE-AUTHORITY) +
  `ArchEscalation` (écriture de l'escalade humaine) + `GatekeeperSeal` (sceau de merge, autorité
  EXTERNE partagée avec `StepRunCompleter.promote`) → ø. Ce module ne NOMME JAMAIS `StepDispatcher` :
  le flux review descend vers les feuilles, il ne remonte pas au cœur. Le cœur DÉCIDE (gate PR +
  verdicts lus), ReviewLifecycle AIGUILLE, les feuilles EXÉCUTENT.

  ## Frontière : struct de seams `%Ctx{}` (blindé, `@enforce_keys`)

  Le flux review a besoin d'un large contexte (forge/loader/spawner/task_queue/resolver/repo/forge_opts/
  wake_recovery/opts). Contrairement aux seams ÉTROITS de `Spawn`/`ArchEscalation` (6 / 3 champs, un
  cluster feuille), ce contexte est le paquet complet du dispatch — d'où un struct DÉDIÉ plutôt qu'une
  map nue : `@enforce_keys` force chaque champ à la construction (site UNIQUE : `StepDispatcher.
  dispatch_review/2`) et un accès `ctx.<typo>` ne compile pas (là où `Map.get(ctx, :typo)` passerait en
  silence). Les sous-modules re-construisent `Spawn.Seams`/`ArchEscalation.Seams` depuis ce `Ctx` au
  site d'appel de chaque feuille (frontière étroite préservée).

  ## Helpers PARTAGÉS avec le cœur, threadés SANS cycle ni fork

  `route_for/4` (lecture de la route gravée) et `tag_err/2` (tagging d'erreur de résolution) sont
  utilisés par les DEUX flux (issue `dispatch_issue` AU CŒUR + review ici). Ils RESTENT définis au cœur
  (leur home : le flux issue les appelle en direct) et sont threadés vers le flux review par CAPTURE
  dans le `Ctx` (`route_reader` / `err_tagger`), exactement comme `resolver`/`wake_recovery` — la
  capture est créée AU CŒUR, donc ce flux n'a aucune référence compile-time vers
  `StepDispatcher` (dépendance strictement uni-directionnelle, pas de cycle) sans dupliquer les deux
  helpers (pas de fork).
  """

  require Logger

  # Feuille de spawn SINGLE-AUTHORITY : `safe_kill/2` (die-on-promote) — même autorité que le
  # spawn des juges/rework (via RoleDispatch), jamais un fork.
  alias Fleet.Pilot.StepDispatcher.Spawn

  # Remédiation BORNÉE (rework budget forge-natif / conflit via IncidentRegistry) — DÉCIDE, puis
  # redescend sur RoleDispatch (re-spawn producteur) ou ArchEscalation (mur humain).
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.Remediation

  # Feuille d'EXÉCUTION du spawn PR-role (juge/rework/résolution) : résolutions read-only puis
  # Spawn.spawn_step. Partagée aiguillage ↔ remédiation (la coupe acyclique du flux).
  alias Fleet.Pilot.StepDispatcher.ReviewLifecycle.RoleDispatch

  defmodule Ctx do
    @moduledoc """
    Contexte complet du flux review, construit au site UNIQUE `StepDispatcher.dispatch_review/2` et
    threadé à travers l'aiguillage/rework/promotion. Struct DÉDIÉ (pas une map) : `@enforce_keys`
    force chaque champ, un accès `ctx.<typo>` ne compile pas. `route_reader`/`err_tagger` sont les
    captures des helpers du cœur (`route_for`/`tag_err`) partagés avec le flux issue.
    """
    @enforce_keys [
      :forge,
      :loader,
      :spawner,
      :task_queue,
      :resolver,
      :repo,
      :forge_opts,
      :wake_recovery,
      :opts,
      :route_reader,
      :err_tagger
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            # Client forge injecté (seam `:forge_client`, défaut prod `Fleet.Pilot.ForgeClient`).
            forge: module(),
            # Loader de cap-profile injecté (seam `:loader`, défaut prod `Fleet.CapProfile`).
            loader: module(),
            # Spawner injecté (seam `:spawner`, défaut prod `Fleet.Spawner`).
            spawner: module(),
            # Broker de briefs injecté (seam `:task_queue`, défaut prod `Fleet.TaskQueue`).
            task_queue: module(),
            # Résolveur projet injecté (seam `:project_resolver`, défaut `&default_project_resolver/2`).
            resolver: (String.t(), keyword() -> {:ok, map() | nil} | {:error, term()}),
            # `owner/name` du repo (PR + issue parente y vivent).
            repo: String.t(),
            # Opts forge (base_url/token…) passés au ForgeClient.
            forge_opts: keyword(),
            # Recovery de wake injecté (seam `:wake_recovery`, défaut `&Fleet.Pilot.WakeRecovery.wake/3`).
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()}),
            # Le keyword `opts` brut du dispatch (base des `review_opts`, budgets, seam d'incident registry).
            opts: keyword(),
            # Capture de `StepDispatcher.route_for/4` (lecture de la route gravée) — partagée avec le flux issue.
            route_reader: (module(), String.t(), integer(), keyword() ->
                             {:ok, {String.t(), String.t()} | nil} | {:error, term()}),
            # Capture de `StepDispatcher.tag_err/2` (tagging d'erreur de résolution) — partagée avec le flux issue.
            err_tagger: (term(), atom() -> term())
          }
  end

  # ============================================================
  # Aiguillage (entrée du flux review)
  # ============================================================

  @doc """
  Aiguillage REVIEWS-DRIVEN (la source de vérité = les reviews postées, PAS `requested_reviewers`
  que Gitea ne vide pas). Sans branch-protection : LCARS agrège (décision user). ORDRE :
    1. un juge demandé SANS verdict décisif → round actif → on le spawn (sérialisé par le verrou PR).
       Un juge déjà décisif (même encore listé dans requested_reviewers) n'est PAS re-spawné → fin de
       la boucle de re-spawn.
    2. tous les demandés ont un verdict + au moins un `:changes_requested` → rework du producteur.
    3. tous les demandés ont APPROUVÉ → MERGE (scellé gatekeeper).
    4. aucun juge demandé → no_verdict (PR sans review-request, surfacé).

  Point d'entrée du flux review : `StepDispatcher.dispatch_review/2` y délègue après le gate PR + la
  lecture de `pr_review_state`. `requested` = union(requested_reviewers volatil, jury stable) ;
  `verdicts` = map `login → verdict` commit-scopée.
  """
  @spec dispatch_by_verdicts([String.t()], map(), integer(), String.t(), Ctx.t()) ::
          {:ok, tuple()} | {:skipped, term()} | {:error, term()}
  def dispatch_by_verdicts(requested, verdicts, pr_number, head, %Ctx{} = ctx) do
    pending = requested -- Map.keys(verdicts)

    cond do
      pending != [] ->
        RoleDispatch.dispatch(:judge, pr_number, head, hd(pending), ctx)

      requested == [] ->
        {:skipped, :no_verdict}

      Enum.any?(Map.values(Map.take(verdicts, requested)), &(&1 == :changes_requested)) ->
        Remediation.dispatch_rework(pr_number, head, ctx)

      true ->
        # Tous approuvé → MERGE. Si le merge échoue sur un CONFLIT (PR approuvée mais
        # `main` a avancé + même fichier édité), on ne remonte PAS l'erreur sèche (= retry-à-l'infini avec un
        # sceau mensonger). On RÉSOUT (rebase producteur), borné par l'IncidentRegistry (récurrence → escalade arch).
        case promote_pr(pr_number, head, ctx) do
          {:error, {:merge, reason}} ->
            Remediation.dispatch_conflict_resolution(pr_number, head, reason, ctx)

          other ->
            other
        end
    end
  end

  # ============================================================
  # Promotion (merge scellé gatekeeper)
  # ============================================================

  # PROMOTE PR-state-driven (interim, sans branch-protection) : tous les juges ont
  # approuvé → le système SCELLE. Comment de fin + merge signés GATEKEEPER
  # (gardien des PRs — « c'est dans son nom » ; token de rôle, `as_role`). Comment HONNÊTE
  # (on ne ment pas, on montre) : livré par l'eng, validé par les juges (APPROVED), mergé
  # par le système (branch-protection OFF en dev → LCARS agrège, pas Gitea — explicité). Le merge
  # `rebase` (LINÉAIRE, gère un `main` avancé sous une PR parallèle — multi-issue, cf. merge_pr)
  # auto-close l'issue via `Closes #N` du body PR → close APRÈS merge, jamais avant. Pas de verrou
  # (poller mono-process) ; PR déjà mergée → 409 → la PR disparaît au tick suivant (idempotent).
  #
  # `promote_comment` + le rôle gatekeeper + le merge vivent dans `Fleet.Pilot.GatekeeperSeal`
  # (sceau UNIQUE partagé avec `StepRunCompleter.promote` — pas de fork de signature de merge).
  defp promote_pr(pr_number, head, %Ctx{} = ctx) do
    with {:ok, {issue_n, producer}} <- RoleDispatch.parse_feature_branch_or_skip(head) do
      # Sceau UNIQUE partagé avec `StepRunCompleter.promote` : commentaire gatekeeper + merge
      # signé gatekeeper. La signature est posée EN INTERNE par `seal_and_merge` (writer unique
      # `GatekeeperSeal.as_gatekeeper/1`) — un chemin de merge séparé forkerait en token système
      # (l'escalade signerait `system`).
      case Fleet.Pilot.GatekeeperSeal.seal_and_merge(
             ctx.forge,
             ctx.repo,
             pr_number,
             issue_n,
             producer,
             ctx.forge_opts
           ) do
        :ok ->
          # Die-on-promote (best-effort). Le producteur est `one-shot` : il est DÉJÀ mort en fin de
          # build/rework → ce kill est un no-op dans le cas nominal. On garde DÉLIBÉRÉMENT `for_issue`
          # (pas `for_repo`) : pour un producteur `slot_scope: project`, `for_issue(issue_n, producer)`
          # cible un pod_id PHANTÔME (`<repo>-issue-N-engineer` n'existe pas — l'identité projet est
          # `<repo>-engineer`) → no-op SÛR. Utiliser `for_repo` ici TUERAIT l'eng s'il code déjà une
          # AUTRE issue (pod projet partagé) = bug « kill the wrong eng ». À revisiter SEULEMENT si un
          # producteur PIPE (long-lived) est réintroduit (cleanup ciblé non-naïf nécessaire alors).
          _ =
            Spawn.safe_kill(ctx.spawner, Fleet.Pilot.PodId.for_issue(ctx.repo, issue_n, producer))

          Logger.info(
            "StepDispatcher: PROMOTE pr=#{ctx.repo}##{pr_number} issue=##{issue_n} " <>
              "(juges OK → merge rebase, scellé gatekeeper, close via Closes ##{issue_n} ; eng tué)"
          )

          {:ok, {:merged, pr_number}}

        {:error, _} = err ->
          err
      end
    end
  end
end
