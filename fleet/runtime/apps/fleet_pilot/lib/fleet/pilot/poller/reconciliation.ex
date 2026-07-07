defmodule Fleet.Pilot.Poller.Reconciliation do
  @moduledoc """
  Cluster IMPUR « réconciliation des verrous orphelins » extrait de `Fleet.Pilot.Poller`.

  Un verrou `lcars-in-flight` est ORPHELIN si la brique le porte mais qu'aucun pod vivant ne la
  travaille. Cause : un pod mort (deadline `:result_timeout`, crash, restart BEAM) reapé par le
  PodWarden — qui retire le PROCESS mais PAS le label forge. Symétrie cassée → sans réparation le
  `dispatch_*` skip la brique `:in_flight` POUR TOUJOURS (un seul stall de pod wedge le pipe). Ce
  module RÉPARE : à chaque tick, il compare les verrous vus sur la forge aux refs qu'un pod VIVANT
  possède réellement, et réclame (retire le label) les orphelins CONFIRMÉS → le prochain tick
  re-dispatche.

  ## Ce que ce module fait / ne fait PAS

  Il LIT 5 seams (`%Seams{}`) et rend le NOUVEAU set de suspects (`MapSet.t()`) — il n'ÉCRIT aucun
  state du poller. La **grâce 2-tick** (n'accumuler un suspect que sur deux ticks consécutifs) et
  l'**agrégation cross-repo** (`MapSet.union` des suspects de tous les repos d'un tick) sont de
  l'état CROSS-TICK : elles RESTENT au cœur (`Fleet.Pilot.Poller` — `do_poll`/`step_do_poll` passe
  les suspects du tick précédent en `prior_suspects` et ré-écrit le set rendu dans le state).

  ## Grâce 2-tick + refs REPO-QUALIFIÉES (sémantique load-bearing, verbatim)

  On ne réclame qu'un orphelin CONFIRMÉ : `reconcile/5` intersecte les orphelins vus CE tick avec
  `prior_suspects` (les orphelins vus au tick PRÉCÉDENT) — jamais un pod fraîchement dispatché (pas
  encore registré) ou en cours de mort. Les refs de verrou sont REPO-QUALIFIÉES
  (`{repo, :issue|:pr, n}`) : la clé porte le repo, donc les refs des pods vivants (`owned`, scopées
  au repo courant) et les suspects cross-tick (tous repos) ne collisionnent plus sur le seul numéro.
  Un orphelin #N/repoA n'est plus masqué par un pod vivant #N/repoB, et la grâce ne se contamine plus
  entre repos.

  ## Fail-safe (verbatim)

  Si l'énumération des pods vivants échoue (`live_owned_refs/1 → :error`), on ne réclame RIEN et on
  garde `prior_suspects` en l'état — ne JAMAIS déverrouiller à l'aveugle.

  ## Frontière : struct de seams explicite (pas le `state` entier)

  Le cluster ne lit que 5 seams du poller (`forge`/`spawner`/`task_queue`/`repo`/`forge_opts`). On
  NE passe PAS le `state` entier — ce serait une fuite de frontière. Le caller construit un
  `%Seams{}` (contrat étroit, TYPÉ) : `@enforce_keys` force les 5 champs à l'appel, et un accès
  `seams.<autre_champ>` ne compile pas (KeyError statique) — une map nue laisserait passer
  `Map.get(seams, :orphan_lock_suspects)` en silence. Le caller résout les défauts prod
  (`state.spawner || Fleet.Spawner`, `state.task_queue || Fleet.TaskQueue`) à SON site : le cluster
  reçoit des modules déjà résolus.

  Dépendances (jamais `Fleet.Pilot.Poller` → pas de cycle) : `Fleet.Pilot.Labels` (source unique du
  verrou), `Fleet.Pilot.PodId` (format des pod_ids), `Fleet.Pilot.IssueId` (parse issue_id) + les
  seams injectés (spawner/task_queue/forge).
  """

  require Logger

  # Verrou workflow_run : source unique `Fleet.Pilot.Labels` (constante compile-time). MÊME source que
  # le `@in_flight` du cœur `Poller` (qui garde le sien pour le fast-path `classify_issue`) — pas un
  # fork de littéral, l'autorité reste `Labels.in_flight/0`.
  @in_flight Fleet.Pilot.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Contrat de frontière de la réconciliation : les 5 seams (et RIEN d'autre) que `reconcile/5` lit.
    `@enforce_keys` force les 5 champs à la construction ; un accès `seams.<autre_champ>` ne compile
    pas — le cluster ne reçoit jamais le `state` entier du poller. `spawner`/`task_queue` sont déjà
    RÉSOLUS par le caller (défauts prod `Fleet.Spawner`/`Fleet.TaskQueue` appliqués à son site).
    """
    @enforce_keys [:forge, :spawner, :task_queue, :repo, :forge_opts]
    defstruct [:forge, :spawner, :task_queue, :repo, :forge_opts]

    @type t :: %__MODULE__{
            # Client forge injecté (seam `:forge_client`, défaut prod `Fleet.Pilot.ForgeClient`).
            forge: module(),
            # Spawner injecté, DÉJÀ résolu par le caller (seam `:spawner`, défaut prod `Fleet.Spawner`).
            spawner: module(),
            # Broker injecté, DÉJÀ résolu par le caller (seam `:task_queue`, défaut prod `Fleet.TaskQueue`).
            task_queue: module(),
            # `owner/name` du repo courant (les refs de verrou y sont repo-qualifiées).
            repo: String.t(),
            # Opts forge (base_url/token…) passés au ForgeClient (`remove_label`).
            forge_opts: keyword()
          }
  end

  @doc """
  Réconcilie les verrous `lcars-in-flight` orphelins du repo `seams.repo` et rend le NOUVEAU set de
  suspects (`MapSet.t()` de refs repo-qualifiées `{repo, :issue|:pr, n}`).

  `prior_suspects` = les orphelins vus au tick PRÉCÉDENT (grâce 2-tick, portée par le cœur). Effet de
  bord : retire le label forge (`reclaim_lock/2`) des orphelins CONFIRMÉS (vus les deux ticks). Le
  set rendu = les orphelins de CE tick pas encore réclamés (ceux qui attendent leur 2ᵉ confirmation).

  Fail-safe : si l'énumération des pods échoue (`:error`), rend `prior_suspects` inchangé (ne réclame
  rien à l'aveugle).
  """
  @spec reconcile(list(map()), list(map()), MapSet.t(), MapSet.t(), Seams.t()) :: MapSet.t()
  def reconcile(issues, pulls, pr_issue_ids, prior_suspects, %Seams{} = seams) do
    case live_owned_refs(seams) do
      # Énumération des pods indisponible → fail-safe : on ne réclame RIEN (ne jamais déverrouiller
      # à l'aveugle), on garde les suspects en l'état.
      :error ->
        prior_suspects

      owned ->
        repo = seams.repo

        # Orphelins REPO-QUALIFIÉS (`{repo, :issue|:pr, n}`) : la clé de verrou porte le repo, donc
        # `owned` (refs repo-scopées des pods vivants de CE repo) et `prior_suspects` (cross-tick, tous
        # repos) ne collisionnent plus sur le seul numéro. Un orphelin #N/repoA n'est plus masqué par un
        # pod vivant #N/repoB, et la grâce 2-tick ne se contamine plus entre repos.
        issue_orphans =
          for i <- issues,
              n = i["number"],
              locked?(i),
              # une issue avec PR ouverte est en phase JUGE (verrou côté PR) → pas un orphelin issue
              not MapSet.member?(pr_issue_ids, n),
              not MapSet.member?(owned, {repo, :issue, n}),
              into: MapSet.new(),
              do: {repo, :issue, n}

        pr_orphans =
          for p <- pulls,
              n = p["number"],
              locked?(p),
              not MapSet.member?(owned, {repo, :pr, n}),
              into: MapSet.new(),
              do: {repo, :pr, n}

        orphaned_now = MapSet.union(issue_orphans, pr_orphans)
        to_reclaim = MapSet.intersection(orphaned_now, prior_suspects)
        Enum.each(to_reclaim, fn {_repo, _type, n} -> reclaim_lock(seams, n) end)
        MapSet.difference(orphaned_now, to_reclaim)
    end
  end

  # Refs `{repo, :issue|:pr, n}` qu'un pod travaille RÉELLEMENT, dérivées des pod_ids déterministes STABLES
  # (`<repo-slug>-issue-<n>-<role>` / `<repo-slug>-pr-<n>-<role>` ; pas de suffixe timestamp).
  # Filtre par **tâche active** (TaskQueue) : un verrou n'est légitimement tenu QUE pendant qu'un pod a une
  # tâche active dessus. Un pod VIVANT mais IDLE (long-lived entre deux reworks, ex. l'engineer) ne « possède »
  # PAS le verrou — sinon il masquerait un juge MORT et la réconciliation ne réclamerait jamais (wedge).
  # `:error` si l'énumération échoue (fail-safe : on ne réclame rien à l'aveugle).
  #
  # SCOPE REPO : on ne garde QUE les pods de `seams.repo` (préfixe `PodId.scope_prefix/1`), et la ref
  # rendue PORTE le repo (`{repo, :issue|:pr, n}`). Sans ça, un pod vivant #N/repoB « posséderait » la ref
  # `{:issue, N}` globale → il MASQUERAIT l'orphelin #N/repoA (verrou jamais réclamé = wedge) ET la grace
  # 2-tick se contaminerait cross-repo (double-spawn). La clé de verrou REPO-QUALIFIÉE = l'identité réelle.
  #
  # G1 — une brique sous ÉVAL GATEKEEPER est possédée AUSSI : pendant l'éval (un tour claude = minutes),
  # le pod PRODUCTEUR est fini (mort one-shot ou idle) et le GATEKEEPER porte la tâche d'éval sous un
  # pod_id `permanent-*` (aucun slug repo) → sans `gate_eval_owned_refs`, la ref paraissait orpheline et
  # la grâce 2-tick (~60s) la RÉCLAMAIT en pleine éval → re-dispatch du step concurrent (double
  # workflow_run + verdict fantôme au retour). L'union se fait DANS le try : un échec d'énumération des
  # évals fait `:error` → le fail-safe « ne rien réclamer » couvre les deux sources.
  defp live_owned_refs(%Seams{spawner: spawner, task_queue: tq, repo: repo}) do
    pod_refs =
      spawner.list_pods()
      |> Enum.filter(&pod_has_active_task?(tq, &1[:pod_id]))
      |> Enum.flat_map(&owned_refs_for_pod(&1[:pod_id], repo, tq))
      |> MapSet.new()

    MapSet.union(pod_refs, gate_eval_owned_refs(tq, repo))
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # G1 — refs possédées par les ÉVALS GATEKEEPER ACTIVES du broker. La source de vérité existe déjà :
  # la tâche d'éval (MA-03, metadata auto-descriptif) porte `gate_eval: true` + `resume_n` (n° d'issue)
  # + `resume_payload.repository.full_name` (repo — multi-projet : une éval de repoB ne possède PAS une
  # ref de repoA). États ACTIFS seulement (`TaskQueue.list_active`) : une éval `:cleared` (clobbée par
  # un supersede à l'enqueue — MA-27 borne à 1 work item actif/pod) ou `:completed` (verdict rendu,
  # resume en vol — fenêtre couverte par la grâce 2-tick) ne possède PLUS sa ref → le reclaim reprend
  # la main et le re-dispatch ré-escalade (self-heal borné par le budget rework). Les évals portent sur
  # des ISSUES (les juges PR passent par dispatch_review, sans gate) → refs `{repo, :issue, n}`.
  # `function_exported?` : un stub task_queue sans `list_active` → MapSet vide (conservateur, même
  # pattern que `pod_active_issue_id` — ne masque rien qu'il ne connaît pas).
  defp gate_eval_owned_refs(tq, repo) do
    if function_exported?(tq, :list_active, 0) do
      for %{metadata: meta} <- tq.list_active(),
          meta["gate_eval"] == true,
          get_in(meta, ["resume_payload", "repository", "full_name"]) == repo,
          n = meta["resume_n"],
          is_integer(n),
          into: MapSet.new(),
          do: {repo, :issue, n}
    else
      MapSet.new()
    end
  end

  # Refs qu'un pod ACTIF possede. Per-issue (instance) : derivees du pod_id (`-issue-N-` / `-pr-N-`).
  # SLOT-FREEZE — project pipe (pod_id `<repo>-engineer`, AUCUN `-issue-N-`) : parse_pod_ref rend [] (son
  # id n'encode pas la brique), donc on derive la brique de sa TACHE ACTIVE (`issue_id` = `issue-N`).
  # Sinon le poller croit l'eng resident proprietaire d'AUCUN verrou -> reclame le sien -> boucle.
  defp owned_refs_for_pod(pod_id, repo, tq) do
    case parse_pod_ref(pod_id, repo) do
      [] -> project_pod_owned_refs(pod_id, repo, tq)
      refs -> refs
    end
  end

  # Un pod project-scoped de CE repo (prefixe scope) possede la ref de sa tache active (`issue-N` ->
  # {repo, :issue, N}). Garde le SCOPE repo : un eng d'un autre repo ne possede pas une ref de seams.repo.
  # function_exported? : un stub task_queue sans la fn -> [] (conservateur, ne masque rien).
  defp project_pod_owned_refs(pod_id, repo, tq) do
    with true <- String.starts_with?(pod_id, Fleet.Pilot.PodId.scope_prefix(repo)),
         true <- function_exported?(tq, :pod_active_issue_id, 1),
         {:ok, issue_id} when is_binary(issue_id) <- tq.pod_active_issue_id(pod_id),
         {:ok, n} <- Fleet.Pilot.IssueId.parse(issue_id) do
      [{repo, :issue, n}]
    else
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Un pod a-t-il une tâche ACTIVE (assignée, non close) ? `{:ok, nil}` = idle. Tolérant (toute
  # anomalie → `false` : un pod dont on ne peut établir l'activité ne masque pas un orphelin).
  defp pod_has_active_task?(tq, pod_id) when is_binary(pod_id) do
    case tq.pod_status(pod_id) do
      {:ok, nil} -> false
      {:ok, _status} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp pod_has_active_task?(_tq, _), do: false

  # Refs de verrou qu'un pod d'INSTANCE possede, deduites de son pod_id. Le FORMAT (`issue|pr` + numero)
  # vit dans `Fleet.Pilot.PodId.parse_ref/2` (l'autorite qui le construit) ; ici on ne fait que SCOPER au
  # repo courant et habiller la ref. Effet du scope : un pod d'un AUTRE repo rend `:error` (son slug
  # differe) -> il ne « possede » pas une ref de `seams.repo` -> fin du masquage cross-repo (#N/repoB
  # masquant l'orphelin #N/repoA). La ref rendue PORTE le repo (`{repo, :issue|:pr, n}`) = la cle complete
  # (l'identite reelle du verrou).
  defp parse_pod_ref(pod_id, repo) when is_binary(pod_id) and is_binary(repo) do
    case Fleet.Pilot.PodId.parse_ref(pod_id, repo) do
      {:ok, {phase, n}} -> [{repo, phase, n}]
      :error -> []
    end
  end

  defp parse_pod_ref(_, _), do: []

  defp locked?(item) do
    @in_flight in Enum.map(Map.get(item, "labels") || [], & &1["name"])
  end

  defp reclaim_lock(%Seams{forge: forge, repo: repo, forge_opts: forge_opts}, number) do
    Logger.warning(
      "Poller: réconciliation : verrou #{@in_flight} ORPHELIN sur " <>
        "#{repo}##{number} (pod mort sans complétion) → réclamé (re-dispatch au prochain tick)"
    )

    # Stopwatch : arrêté AUSSI ici (pod mort = jamais passé par `unlock`) — sinon il tournerait jusqu'au
    # prochain unlock réel, comptant le temps mort comme du travail. Best-effort, symétrique du spawn —
    # MAIS signé forge_opts BRUT (système), PAS `as_role` : le pod mort a EMPORTÉ son identité de rôle
    # (aucune trace exploitable à ce point, orphelin = plus aucun pod vivant à interroger). Gitea exige
    # la MÊME identité pour stop que pour start (per-utilisateur) → CE stop ne matchera PAS le stopwatch
    # démarré `as_role` par le pod mort (limite connue, assumée : cas d'échec pod, pas le chemin nominal
    # — cf. `Fleet.Pilot.StepDispatcher.Spawn`/`StepRunCompleter.unlock` pour l'attribution nominale).
    _ = forge.stop_stopwatch(repo, number, forge_opts)
    forge.remove_label(repo, number, @in_flight, forge_opts)
  end
end
