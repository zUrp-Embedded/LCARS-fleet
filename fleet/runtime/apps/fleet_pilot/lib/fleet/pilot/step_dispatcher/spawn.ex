defmodule Fleet.Pilot.StepDispatcher.Spawn do
  @moduledoc """
  Feuille de spawn SINGLE-AUTHORITY extraite de `Fleet.Pilot.StepDispatcher`.

  Les DEUX flux du dispatcher — issue (`dispatch_issue`, producteur) ET PR (`do_dispatch_review`,
  juge/rework/résolution) — CONVERGENT ici : un seul point de spawn (`spawn_step/9`), une seule
  identité de pod (`pod_id_for_scope/4`), une seule sérialisation de scope (`serialize_project_scope/6`).
  Ce module ne DÉCIDE de rien (route, rôle, verdict, budget restent le cœur `StepDispatcher`) : il
  EXÉCUTE la séquence de spawn. Il n'existe qu'UNE copie de chaque — jamais un fork issue/review.
  (Les builders d'opts / naming — `rc_name`/`feature_slug`/`maybe_put_route`/`resolve_repo_id` —
  vivent dans le sous-module `Spawn.Naming`, quasi-purs, appelés par les deux flux.)

  ## Sémantique LOAD-BEARING (préservée mot-pour-mot depuis le cœur)

  - **Ordre canonique** `verrou → pod → enqueue → wake` (le wake EN DERNIER). Le label-verrou
    `lcars-in-flight` est posé AVANT le pod, sinon double-spawn.
  - **Compensation** : si une étape POST-verrou échoue, on retire le verrou ET on kill le pod
    SEULEMENT s'il vient d'être spawné frais (`alive_before? == false`) — un re-brief sur un pod
    vivant ne tue JAMAIS l'eng ni son contexte.
  - **Retour `{:error, {:wake_unreached, pod_id, role, reason}}`** : le pod EST démarré (verrou +
    brief + pod en place), seul le wake tmux a raté. Le POLLER lit ce retour pour PRENDRE le bail
    (l'objet est in-flight) et le compter en `errors` (tally honnête, pas un succès silencieux). Ce
    contrat de retour NE change PAS.

  ## Frontière : struct de seams explicite (pas le `ctx`/`opts` entier)

  `spawn_step/9` ne lit que 6 seams du dispatch. On NE passe PAS le `ctx`/`opts` entier — ce serait
  une fuite de frontière. Chaque caller (issue via `opts`, review via `ctx`) construit un `%Seams{}`
  (contrat étroit, TYPÉ) : `@enforce_keys` force les 6 champs à l'appel, et un accès
  `seams.<autre_champ>` ne compile pas (KeyError statique) — une map nue laisserait passer
  `Map.get(seams, :loader)` en silence.

  Les helpers PARTAGÉS avec le cœur restent PUBLICS ici et sont appelés par `StepDispatcher` :
  `safe_kill/2` (compensation dans `spawn_step` ET die-on-promote dans `promote_pr`).
  """

  require Logger

  # Vocabulaire protocole = source unique Fleet.Pilot.Labels (constante compile-time, comme dans
  # StepDispatcher qui garde SON @in_flight_label pour `decide/1`/`dispatch_review` — même source,
  # pas un fork).
  @in_flight_label Fleet.Pilot.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Contrat de frontière de la feuille de spawn : les 6 seams (et RIEN d'autre) que `spawn_step/9`
    lit. `@enforce_keys` force les 6 champs à la construction ; un accès `seams.<autre_champ>` ne
    compile pas — le cluster ne reçoit jamais le `ctx`/`opts` entier du dispatch.
    """
    @enforce_keys [:forge, :spawner, :task_queue, :repo, :forge_opts, :wake_recovery]
    defstruct [:forge, :spawner, :task_queue, :repo, :forge_opts, :wake_recovery]

    @type t :: %__MODULE__{
            # Client forge injecté (seam `:forge_client`, défaut prod `Fleet.Pilot.ForgeClient`).
            forge: module(),
            # Spawner injecté (seam `:spawner`, défaut prod `Fleet.Spawner`).
            spawner: module(),
            # Broker de briefs injecté (seam `:task_queue`, défaut prod `Fleet.TaskQueue`).
            task_queue: module(),
            # `owner/name` du repo (l'objet verrouillé y vit).
            repo: String.t(),
            # Opts forge (base_url/token…) passés au ForgeClient.
            forge_opts: keyword(),
            # Recovery de wake injecté (seam `:wake_recovery`, défaut `&Fleet.Pilot.WakeRecovery.wake/3`).
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()})
          }
  end

  # ============================================================
  # Cluster H — feuille de spawn (SINGLE-AUTHORITY)
  # ============================================================

  @doc """
  LEAF de spawn partagé par dispatch_issue (producteur) ET do_dispatch_review (juge/rework).
  ORDRE CANONIQUE : label-verrou `lcars-in-flight` AVANT pod (sinon double-spawn) → pod
  (`maybe_spawn` : RE-BRIEFE si vivant) → enqueue du brief (que le pod pull via get_work_item) →
  wake+recovery. Échec POST-verrou → compensation : retrait du verrou (+ kill SI frais spawn,
  JAMAIS un re-brief vivant). `lock_target` = l'objet verrouillé (issue number | PR number) ;
  `issue_number` = le numéro d'issue pour le `issue_id` ET l'enqueue ; `log_ctx` = contexte de log caller.
  """
  @spec spawn_step(
          Seams.t(),
          String.t(),
          String.t(),
          Fleet.CapProfile.t(),
          String.t(),
          keyword(),
          integer(),
          integer(),
          String.t()
        ) :: {:ok, {:spawned, String.t(), String.t()}} | {:error, term()}
  def spawn_step(
        %Seams{} = seams,
        pod_id,
        role,
        profile,
        brief,
        spawn_opts,
        lock_target,
        issue_number,
        log_ctx
      ) do
    %Seams{
      forge: forge,
      spawner: spawner,
      task_queue: task_queue,
      repo: repo,
      forge_opts: forge_opts,
      wake_recovery: wake_recovery
    } = seams

    issue_id = Fleet.Pilot.IssueId.compose(issue_number)
    alive_before? = pod_alive?(spawner, pod_id)

    with {:ok, _} <- forge.add_label(repo, lock_target, @in_flight_label, forge_opts),
         # Time-tracking natif (best-effort, discard) : DÉMARRE le stopwatch sur le MÊME objet que le
         # verrou (issue ou PR) — mécanique globale, agnostique du rôle (cf. § Time-tracking, ForgeClient).
         _ = forge.start_stopwatch(repo, lock_target, forge_opts),
         {:ok, _} <- maybe_spawn(spawner, alive_before?, profile, issue_id, spawn_opts),
         :ok <- enqueue_brief(task_queue, pod_id, role, issue_number, brief) do
      # Le retour de `WakeRecovery.wake` est LOAD-BEARING : `{:error, {:escalated, _}}`
      # (pod injoignable, escaladé à starfleet) ou `{:error, _}` (re-wake KO) signifie que le pod n'est
      # PAS réveillé. Jeter ce retour (`_ = wake(...)`) ferait toujours rendre `spawn_step`
      # `{:ok, {:spawned}}` → le poller compterait `dispatched +1 / errors 0` MENTEUR (pod jamais réveillé,
      # mais tally clean). On le MATCHE donc : le verrou + le brief + le pod RESTENT en place (le
      # brief est enqueué, l'escalade système existe → pas un cul-de-sac, re-wake au prochain tick), mais
      # le dispatch n'est PAS un succès silencieux — il remonte `{:error, {:wake_unreached, …}}` → le poller
      # le compte en `errors` (tally honnête + err_streak/telemetry reflètent l'injoignabilité réelle).
      case wake_recovery.(
             pod_id,
             fn -> maybe_spawn(spawner, false, profile, issue_id, spawn_opts) end,
             wake_fun: fn p -> safe_wake(spawner, p) end
           ) do
        :ok ->
          Logger.info(
            "StepDispatcher: #{disposition(alive_before?)} role=#{role} pod=#{pod_id} #{log_ctx}"
          )

          {:ok, {:spawned, pod_id, role}}

        {:error, reason} ->
          # PAS de compensation : verrou conservé (le pod est dispatché, l'objet EST in-flight),
          # brief conservé, pod conservé. Seul le réveil a échoué → tally honnête + re-wake au tick suivant
          # (idempotent : alive_before? sera vrai, maybe_spawn no-op, re-wake retenté).
          Logger.warning(
            "StepDispatcher: #{disposition(alive_before?)} role=#{role} pod=#{pod_id} #{log_ctx} " <>
              "MAIS wake INJOIGNABLE → #{inspect(reason)} (verrou+brief conservés, re-wake au prochain tick ; " <>
              "tally = error, pas dispatched silencieux)"
          )

          {:error, {:wake_unreached, pod_id, role, reason}}
      end
    else
      {:error, _} = err ->
        # Une étape POST-verrou a échoué → compensation (retrait du verrou, sinon stuck à jamais).
        # Kill SEULEMENT si frais spawn (un re-brief ne tue JAMAIS l'eng vivant + son contexte).
        if not alive_before?, do: safe_kill(spawner, pod_id)
        _ = forge.remove_label(repo, lock_target, @in_flight_label, forge_opts)

        # Stopwatch démarré avec le verrou → arrêté avec lui (le dispatch n'a jamais abouti, le temps
        # écoulé serait du bruit, pas du travail réel).
        _ = forge.stop_stopwatch(repo, lock_target, forge_opts)

        Logger.warning(
          "StepDispatcher: dispatch role=#{role} pod=#{pod_id} #{log_ctx} → #{inspect(err)} " <>
            "(verrou retiré#{if(not alive_before?, do: ", pod tué", else: "")} — re-dispatch au prochain tick)"
        )

        err
    end
  end

  defp maybe_spawn(_spawner, true = _alive?, _profile, _issue_id, _spawn_opts),
    do: {:ok, :rebriefed}

  defp maybe_spawn(spawner, false = _alive?, profile, issue_id, spawn_opts) do
    case spawner.spawn_pod(profile, issue_id, spawn_opts) do
      {:ok, _pid} -> {:ok, :spawned}
      {:error, _} = err -> err
    end
  end

  defp disposition(true = _alive_before?), do: "re-briefed (pod vivant, contexte gardé)"
  defp disposition(false = _alive_before?), do: "spawned"

  # Enqueue le brief dans le broker `Fleet.TaskQueue` ciblé pod_id — le claude REPL le pull via
  # `mcp__fleet__get_work_item` → `PodTools.get_work_item` → `TaskQueue.get_for_pod` (PAS un Read fichier).
  # Sans cet enqueue, `TaskQueue.pod_status(pod_id) == nil` → le pod se croit bootstrap
  # (rien à puller) → idle.
  # Le `brief` = le BRIEF role-aware déjà construit (build_brief) : GateBrief désamorcé pour le
  # gatekeeper, corps de l'issue pour un worker. Un `issue["body"]` brut ferait
  # puller au juge le brief BUILD exécutable. `metadata.issue` corrèle au issue.
  defp enqueue_brief(task_queue, pod_id, role, number, brief) do
    attrs = %{
      issue_id: Fleet.Pilot.IssueId.compose(number),
      role: role,
      brief: brief,
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

  @doc """
  Compensation best-effort : tue le pod (s'il a spawné) avant de retirer le verrou.
  No-op silencieux si le spawner n'expose pas `kill_pod/1` ou si le pod n'existe pas.

  PUBLIC car partagé avec le cœur : `spawn_step/9` (compensation) ET `StepDispatcher.promote_pr`
  (die-on-promote de l'eng). Une seule copie, pas de fork.
  """
  @spec safe_kill(module(), String.t()) :: any()
  def safe_kill(spawner, pod_id) do
    if function_exported?(spawner, :kill_pod, 1), do: spawner.kill_pod(pod_id), else: :ok
  rescue
    _ -> :ok
  end

  # Dispatch idempotent. Un pod déjà VIVANT (id déterministe stable) = l'eng pipe long-lived
  # → on le RE-BRIEFE (enqueue + wake, garde son contexte), pas de re-spawn (plus de leak/orphelin).
  # `pod_alive?` défaute à `false` si le spawner n'expose pas `pod_info/1` (stubs de test) → chemin
  # spawn inchangé.
  defp pod_alive?(spawner, pod_id) do
    function_exported?(spawner, :pod_info, 1) and match?({:ok, _}, spawner.pod_info(pod_id))
  rescue
    _ -> false
  end

  # ============================================================
  # Cluster I — identité pod + sérialisation de scope (SINGLE-AUTHORITY)
  # ============================================================

  @doc """
  Granularité d'identité du pod, dérivée du catalogue (`slot_scope` du cap-profile, source unique) :
    "instance" → keyé ISSUE (`for_issue`) : fan-out, un id distinct par issue/PR (juges éphémères).
    "project"  → keyé REPO seul (`for_repo`) : UNE identité par (repo, rôle) → un slot Desktop stable.
  Total sur l'enum slot_scope (l'accessor `Fleet.CapProfile.slot_scope/1` garantit project|instance).
  """
  @spec pod_id_for_scope(String.t(), String.t(), integer(), String.t()) :: String.t()
  def pod_id_for_scope("project", repo, _number, role),
    do: Fleet.Pilot.PodId.for_repo(repo, role)

  def pod_id_for_scope("instance", repo, number, role),
    do: Fleet.Pilot.PodId.for_issue(repo, number, role)

  @doc """
  Serialisation des roles project-scoped : UNE identite (repo, role) vivante a la fois (1 slot Desktop).
  Module par le lifetime :
    instance         -> jamais gated (ids distincts par issue, fan-out assume).
    project one-shot  -> vivant = occupe par un autre issue -> DEFERE ; il meurt en fin de tache +
                         spawn frais au issue suivant (comportement baseline, INCHANGE).
    project pipe      -> process RESIDENT, selon son etat (pipe_rebrief_state) :
                           dead  -> :ok (spawn frais, 1er issue) ;
                           busy  -> DEFERE (travaille encore une tache OU publie son dernier livrable :
                                    resetter son workspace maintenant le corromprait / courserait le push) ;
                           ready -> reset COLD in-place du workspace pour le nouveau brief + /clear, PUIS
                                    :ok (spawn_step re-brief sur un workspace propre, bonne branche).
  Tout AVANT le verrou/enqueue (sinon on verrouillerait une issue qu'on ne traite pas). `{:skipped,
  :role_busy}` remonte au poller (retry au tick suivant). La base du reset = `project["base_sha"]` :
  nouveau issue -> main tip (fresh) ; rework -> tip de la PR (continue le travail de l'eng). 1 seule fn.
  """
  @spec serialize_project_scope(
          String.t(),
          String.t(),
          module(),
          String.t(),
          map() | nil,
          String.t()
        ) :: :ok | {:skipped, :role_busy}
  def serialize_project_scope("instance", _lifetime, _spawner, _pod_id, _project, _slug), do: :ok

  def serialize_project_scope("project", "one-shot", spawner, pod_id, _project, _slug) do
    if pod_alive?(spawner, pod_id), do: {:skipped, :role_busy}, else: :ok
  end

  def serialize_project_scope("project", _pipe, spawner, pod_id, project, slug) do
    case pipe_rebrief_state(spawner, pod_id) do
      :dead -> :ok
      :busy -> {:skipped, :role_busy}
      :ready -> reprovision_then_proceed(spawner, pod_id, project, slug)
    end
  end

  # Etat d'un pipe project-scoped face a un NOUVEAU brief. :ready = idle ET dernier livrable confirme (ni
  # tache active ni :publishing) — la SEULE situation ou resetter le workspace est sur (le push a deja lu
  # le commit, l'agent n'ecrit plus). pod_info expose conditions + has_active_task (le pod sait les deux).
  defp pipe_rebrief_state(spawner, pod_id) do
    case safe_pod_info(spawner, pod_id) do
      {:ok, %{conditions: conds, has_active_task: active}} ->
        cond do
          active -> :busy
          :publishing in conds -> :busy
          true -> :ready
        end

      # pod_info sans has_active_task (stub partiel) : conservateur -> :busy (un pipe vivant d'etat
      # inconnu n'est PAS resette, juste defere). Absent/erreur -> :dead (spawn frais).
      {:ok, _partial} ->
        :busy

      :error ->
        :dead
    end
  end

  defp safe_pod_info(spawner, pod_id) do
    if function_exported?(spawner, :pod_info, 1) do
      case spawner.pod_info(pod_id) do
        {:ok, info} -> {:ok, info}
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  # Reset COLD in-place du workspace + /clear AVANT le rebrief, puis :ok (proceed). Reset KO -> DEFERE
  # (retry au tick suivant). Pas de project (legacy) ou spawner sans la fn (stub) -> :ok sans reset
  # (degrade honnete : on ne bloque pas, mais sans la garantie cold de ce tour).
  defp reprovision_then_proceed(spawner, pod_id, project, slug) do
    if is_map(project) and function_exported?(spawner, :reprovision_pipe_workspace, 3) do
      case spawner.reprovision_pipe_workspace(pod_id, project, slug: slug) do
        :ok -> :ok
        {:error, _} -> {:skipped, :role_busy}
      end
    else
      :ok
    end
  end

  # (Ex-cluster J — builders d'opts / naming : DÉPLACÉ vers `Spawn.Naming` (rc_name /
  # feature_slug / maybe_put_route / resolve_repo_id). Quasi-purs, partagés par les deux
  # flux du dispatcher — la feuille garde la MÉCANIQUE de spawn, Naming garde les NOMS.)
end
