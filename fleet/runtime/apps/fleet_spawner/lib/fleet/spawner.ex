defmodule Fleet.Spawner do
  @moduledoc """
  Pilote lifecycle pod LCARS v2 (Ring 1 pod primitive).

  Spawne, surveille et termine les pods agents éphémères. Chaque pod est un
  `Fleet.Spawner.Pod` (`gen_statem`) supervisé par `Fleet.Spawner.Supervisor` :
  ses ÉTATS sont les 8 phases du cycle canon (`:allocating → :cleaning →
  :projecting → :injecting → :launching → :monitoring → :extracting →
  :releasing`).

  ## API

    * `spawn_pod/3` — démarre un nouveau pod
    * `kill_pod/1` — termine un pod par son ID
    * `pod_info/1` — retourne l'état courant d'un pod
    * `count_pods/0` — nombre de pods actifs

  ## Restart strategy

  Tous les pods sont `:temporary` (cf. `restart_strategy_for/1`). Le
  `DynamicSupervisor` ne ressuscite JAMAIS un pod —
  un pod mort (normal OU crash) est retiré, point. `lifetime_scope` pilote
  la RECOVERY (`release|recreate`), pas le restart.

  ## Recovery

  State FS minimal `<state_fs_root>/{pipes,runs,pods}/<id>/state.json` =
  **snapshot d'observation** (où en était le pod), pas un état de reconstruction.
  Au (re)spawn, `recover_or_init` lit le snapshot et applique `recovery_action(phase)`
  (`Pod.Recovery`) : phase terminale → `:release` (rien à relancer), tout le reste →
  `:recreate` (from scratch, session NEUVE). La résurrection est un acte **délibéré**
  du boot-orchestrator ; la recovery NE tente JAMAIS `--resume` sur une session morte
  côté serveur (claude exit → pod zombie, prouvé live) — la tâche restée en queue
  re-drive un REPL neuf. Seul le RECALL délibéré (`recall/2`) resume une session.

  ## Génération du pod_id

  Génération `UUID.uuid4()` côté caller (collision-free statistique
  sans coordinateur central).

  ## Exit codes

    * `{:ok, pid}` — pod démarré
    * `{:error, :cap_profile_invalid, reason}` — struct invalide
    * `{:error, {:already_started, pid}}` — pod_id collision
    * `{:error, :invalid_pod_id}` — pod_id non path-safe (hors `[A-Za-z0-9._-]` ou contient `..`)
    * `{:error, :brief_required}` — pod one-shot sans brief
  """

  alias Fleet.Spawner.Pod

  require Logger

  @doc """
  Valide qu'un `pod_id` est sûr comme composant de chemins et de noms de socket/session.

  Le `pod_id` est interpolé dans le pod dir (`~/pods/pod_<id>`), le state FS,
  les sockets tmux/MCP et les noms de session. Cette fonction est donc l'autorité
  publique pour les frontières qui acceptent un `pod_id` fourni par un caller
  externe ou inter-app.
  """
  @spec valid_pod_id?(term()) :: boolean()
  def valid_pod_id?(id) when is_binary(id),
    do: Regex.match?(~r/^[A-Za-z0-9._-]+$/, id) and not String.contains?(id, "..")

  def valid_pod_id?(_), do: false

  @doc """
  Règle R18 : un cap-profile one-shot exige un brief. Autorité partagée (brief_guard +
  les frontières qui valident à l'admission, ex. l'API). nil/absent → false (exempté),
  comme brief_guard.
  """
  @spec brief_required?(Fleet.CapProfile.t()) :: boolean()
  def brief_required?(%Fleet.CapProfile{spec: spec}) do
    get_in(spec, ["invocation", "lifetime_scope"]) == "one-shot"
  end

  @doc """
  Spawn a new pod.

  ## Inputs

    * `cap_profile` — struct `%Fleet.CapProfile{}` issue de `Fleet.CapProfile.compose/2`
    * `issue_id` — événement source (issue Gitea, signal OS, etc.)
    * `opts` :
      * `:pod_id` (default `UUID.uuid4()`) — doit être **path-safe** (`[A-Za-z0-9._-]`, pas de `..`),
        car interpolé dans des paths FS (`~/pods/pod_<id>`, sock, state recovery) ;
        sinon `{:error, :invalid_pod_id}`.
      * `:state_fs_root` (override, default config `:fleet_spawner, :state_fs_root`)
      * `:brief` — le travail du pod (string). **Obligatoire** pour un
        pod `one-shot` (sinon `{:error, :brief_required}`).
      * `:allow_no_brief` — échappatoire admin/diagnostic (bool, default false).
  """
  @spec spawn_pod(Fleet.CapProfile.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_pod(%Fleet.CapProfile{} = cap_profile, issue_id, opts \\ [])
      when is_binary(issue_id) and is_list(opts) do
    case brief_guard(cap_profile, opts) do
      :ok ->
        pod_id = Keyword.get_lazy(opts, :pod_id, &generate_pod_id/0)

        # pod_id file dans des paths FS (pod_dir `~/pods/pod_<id>`, sock_path, state recovery)
        # par interpolation. Défaut UUID = sûr, mais l'override `:pod_id` (step `issue-N-role-ts`, role
        # résolu forge ; permanent `permanent-<name>-ts` ; admin) n'est PAS forcément contrôlé → un `/` ou `..`
        # traverserait hors de `~/pods`. Guard charset path-safe + rejet `..` → refus CLAIR, jamais un
        # path traversé (tous les pod_id légitimes — UUID / catalogue / step — passent).
        if valid_pod_id?(pod_id) do
          # id pod DÉTERMINISTE (stable, sans suffixe timestamp) : un re-dispatch retombe sur le même
          # `pod_id`. Si une TOMBSTONE terminale (`state.json` :succeeded/:released/:killed) d'un cycle
          # précédent subsiste, `recover_or_init` la lirait → `:release` → stop MUET sans launch → boucle
          # orphelin côté poller. On efface la tombstone (state + pod_dir) AVANT spawn → init FRESH.
          # No-op si pas de snapshot / snapshot en vol (recovery :resume/:recreate intacte).
          _ = Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, cap_profile, opts)

          args = %{
            cap_profile: cap_profile,
            issue_id: issue_id,
            pod_id: pod_id,
            opts: opts
          }

          spec = pod_child_spec(args)

          # E5 : retour NORMALISÉ — le type brut de start_child inclut `:ignore`/`{:ok, pid, info}`
          # (jamais produits par notre gen_statem, mais les appelants n'ont pas à porter ce contrat).
          case DynamicSupervisor.start_child(Fleet.Spawner.Supervisor, spec) do
            {:ok, pid} -> {:ok, pid}
            {:ok, pid, _info} -> {:ok, pid}
            :ignore -> {:error, :pod_init_ignored}
            {:error, _} = err -> err
          end
        else
          {:error, :invalid_pod_id}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  RECALL délibéré : ramène vivant l'agent `(projet, role)` depuis son seed checkpointé
  (`projects.work/<projet>/pods/`). Lit la workflow_map (uuid+jsonl), spawn un pod en mode resume :
  `session_id` = l'uuid du seed, `resume: true`, le seed est restauré dans le pod AVANT le launch
  (état :projecting → maybe_recall_restore) → claude `--resume <uuid>` reprend le contexte. Nom Desktop
  `<projet>_<role>`. `allow_no_brief` (le pod resume son contexte, pas idle ; pas de brief neuf).

  `{:ok, pid}` | `{:error, :no_seed}` (aucun seed) | `{:error, term}`.
  """
  @spec recall(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def recall(projet, role) when is_binary(projet) and is_binary(role) do
    case Fleet.Spawner.SeedStore.read_map(projet, role) do
      :none ->
        {:error, :no_seed}

      {:ok, %{uuid: uuid, jsonl: jsonl}} ->
        with {:ok, cap_profile} <- Fleet.CapProfile.load(role) do
          spawn_pod(cap_profile, "recall-#{projet}-#{role}",
            pod_id: "recall-#{projet}-#{role}",
            session_id: uuid,
            resume: true,
            recall_seed_jsonl: jsonl,
            rc_name: "#{projet}_#{role}",
            allow_no_brief: true
          )
        end
    end
  end

  # Invariant rendu structurellement impossible à violer : un pod `one-shot` (1 tâche
  # puis meurt) DOIT porter un brief — sinon il part sans travail (brief générique →
  # claude attend → timeout). Les pods long-lived (`forever`/`run`/`pipe`) pullent leurs
  # tâches via MCP (`yop` → get_work_item) → exemptés (épargne les pods permanents/gatekeeper).
  # Échappatoire admin/diagnostic explicite : `opts[:allow_no_brief]`.
  defp brief_guard(%Fleet.CapProfile{spec: spec} = cap_profile, opts) do
    brief = Keyword.get(opts, :brief)
    # `nil` ET `""` (brief vide — ex. un `build_brief` sur un contexte de step
    # vide/malformé) comptent tous deux comme « pas de brief ».
    has_brief? = is_binary(brief) and brief != ""
    scope = get_in(spec, ["invocation", "lifetime_scope"])

    cond do
      has_brief? ->
        :ok

      Keyword.get(opts, :allow_no_brief, false) ->
        :ok

      # Même verdict que `scope == "one-shot"`, mais via le prédicat PUBLIC partagé
      # `brief_required?/1` (autorité unique de la règle one-shot→brief, aussi appelée
      # à l'admission par l'API) → pas de règle dupliquée qui pourrait diverger.
      brief_required?(cap_profile) ->
        # Diagnosable (pas un refus muet) : distingue clairement le cas.
        Logger.warning(
          "Spawner: spawn_pod refusé (R18) : pod one-shot sans brief — " <>
            "fournir :brief (le travail) ou :allow_no_brief (admin/diagnostic)."
        )

        {:error, :brief_required}

      is_nil(scope) ->
        # Profil sans lifetime_scope déclaré (non validé ?) : exemption par défaut
        # (on ne refuse que le one-shot EXPLICITE), mais on rend le trou visible.
        Logger.warning(
          "Spawner: spawn_pod (R18) : lifetime_scope absent du cap-profile — " <>
            "spawn autorisé sans brief (exemption par défaut, profil à vérifier)."
        )

        :ok

      true ->
        :ok
    end
  end

  @doc """
  Termine un pod par son ID. Retourne `:ok` si trouvé, `{:error, :not_found}` sinon.
  """
  @spec kill_pod(String.t()) :: :ok | {:error, :not_found}
  def kill_pod(pod_id) when is_binary(pod_id) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        # Release DÉLIBÉRÉE d'abord — le handler `:kill` du Pod
        # (`handle_event({:call, from}, :kill, ...)`, `GenServer.call` compatible gen_statem) fait
        # teardown backend + clear_for_pod + état terminal :killed, puis stop. Fallback brutal
        # terminate_child SEULEMENT si le pod ne répond pas (timeout / déjà mort).
        # Jamais de bypass de la transition de release.
        try do
          :ok = GenServer.call(pid, :kill, 5_000)
          :ok
        catch
          :exit, _reason ->
            _ = DynamicSupervisor.terminate_child(Fleet.Spawner.Supervisor, pid)
            :ok
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Reprovisionne le workspace d'un pod pipe RESIDENT pour son issue suivant (slot-freeze) : reset git
  IN-PLACE (PAS de rm_rf — le ws est bind-monte dans le sandbox vivant) sur la base du nouveau `project`
  + `/clear` du contexte REPL. Appele par le dispatcher au re-brief d'un pipe `:ready`. Retourne
  `:ok` | `{:error, _}` (incl. `:not_found` si le pod n'existe pas, `{:reset_failed, _}` si le git echoue).
  """
  @spec reprovision_pipe_workspace(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def reprovision_pipe_workspace(pod_id, project, opts \\ [])
      when is_binary(pod_id) and is_map(project) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        # Git ops bornees (Shell.git 30s chacune) mais reset+clean+checkout peuvent cumuler → call
        # genereux (60s). Un :exit (pod mort pendant le call) → erreur typee, pas de crash appelant.
        try do
          GenServer.call(pid, {:reprovision_pipe_workspace, project, opts}, 60_000)
        catch
          :exit, reason -> {:error, {:reprovision_call_failed, reason}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Workspace livrable depuis un `pod_dir` DÉJÀ connu (`<pod_dir>/workspace`). Point d'entrée
  PUBLIC (frontière d'app : les consommateurs externes ne dépendent pas de l'arborescence interne
  `pod/*`) ; l'AUTORITÉ du calcul (le littéral `"workspace"`) vit dans `Pod.Paths.pod_workspace_path/1`
  — les îles `Pod.*` (LaunchSpec, CompletedPayload) l'appellent en direct, sans remonter à la façade.
  `pod_workspace_dir/1` reste la voie registry : le monde lit où IL a placé le pod, jamais où le pod
  prétend être.
  """
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Fleet.Spawner.Pod.Paths.pod_workspace_path(pod_dir)

  @doc """
  Résout le workspace livrable d'un pod (`<pod_dir>/workspace`) depuis le pod_dir ENREGISTRÉ.
  Le monde lit où IL a placé le pod (record spawner via `pod_info`), pas une assertion du pod :
  le pod ne nomme jamais le chemin de son propre audit. Sert au rail forge-driven
  (`Pilot.StepRunCompleter` → `Deliverable`) pour gater le workspace en mode `git_native`.
  """
  @spec pod_workspace_dir(String.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def pod_workspace_dir(pod_id) when is_binary(pod_id) do
    case pod_info(pod_id) do
      {:ok, %{pod_dir: dir}} when is_binary(dir) -> {:ok, pod_workspace_path(dir)}
      {:ok, _} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Renvoie l'état courant d'un pod (`%{phase, conditions, ...}`).
  """
  @spec pod_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def pod_info(pod_id) when is_binary(pod_id) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        # Le pid peut être mort mais encore brièvement dans le Registry (cleanup
        # async via monitor) — un `GenServer.call` y lèverait `EXIT`. Un pod mort =
        # absent → `{:error, :not_found}` (cohérent avec le pattern try/catch de
        # `kill_pod/1` ; supprime une race exposée par le stop rapide de la release).
        try do
          {:ok, GenServer.call(pid, :info)}
        catch
          :exit, _reason -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Énumère les `:info` des pods vivants — **read seam observabilité** (read-only).

  Liste les clés du `Fleet.Spawner.Registry` et collecte le `:info` de chacun
  via `pod_info/1` ; les pods morts mais encore brièvement registrés (race
  cleanup async monitor, cf. `pod_info/1`) sont écartés. Lecture seule — n'altère
  aucun état. C'est l'unique seam d'énumération exposé : les lecteurs (deck
  d'observabilité Ring 4) passent par ici, **jamais** par le Registry en direct.
  """
  @spec list_pods() :: [map()]
  def list_pods do
    Fleet.Spawner.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn pod_id ->
      case pod_info(pod_id) do
        {:ok, info} -> [info]
        {:error, :not_found} -> []
      end
    end)
  end

  @doc """
  Nombre de pods actifs.
  """
  @spec count_pods() :: non_neg_integer()
  def count_pods do
    %{active: active} = DynamicSupervisor.count_children(Fleet.Spawner.Supervisor)
    active
  end

  @doc """
  Réveille un pod long-lived (lifetime_scope != one-shot) pour un nouveau cycle.

  **Rail porteur = réveil-par-flag** (`turn.flag` + outil Monitor in-pod), touché ICI. Triggers the common
  workflow (`core/runtime-contract` block of the per-role SP):

      (flag touché → Monitor « ton tour ») → mcp__fleet__get_work_item → traite → mcp__fleet__submit_result

  `wake_pod` n'est QUE *trigger + armement du filet* : il touche le flag (porteur), puis ARME (cast)
  la boucle ack-driven du Pod (`:arm_kick` — le FALLBACK : send-keys `"wake"` UNIQUEMENT si le pull n'arrive
  pas) + ré-arme la deadline de RÉPONSE (`:rearm_deadline`). Il ne fait **pas** de send-keys lui-même.

  Pré-requis : le caller a déjà enqueué le brief dans `Fleet.TaskQueue` (ciblé `pod_id` ; le pod s'identifie
  par `_lcars_pod_id` sur le fil) AVANT l'appel. Le CONTENU passe TOUJOURS par MCP (`get_work_item`), jamais par
  le texte injecté.

  Use-cases :
    - pipeline `standard-qa` : après findings reviewer/gatekeeper, push task corrective + wake_pod(eng) ;
    - starfleet/fleet_pilot : nouveau issue assigné au même pod long-lived → push + wake.

  Renvoie — signale UNIQUEMENT si le trigger a pu PARTIR ; le wake RÉEL est ASYNC :
    - `:ok` — flag touché + boucle & deadline armées. **N'affirme PAS que l'agent s'est réveillé** : le
      succès réel = l'ACK (pull) observé par la boucle ; un wake qui ne prend jamais → la boucle escalade au
      cap (`wake.failed` → `:sp_suspect`).
    - `{:error, :not_found}` — pod_id inconnu/mort (jamais spawn, déjà kill, ou pid mourant).
    - `{:error, :not_a_tmux_pod}` — pod sans session tmux (StubBackend des tests ; en prod le backend pose
      toujours un tmux_session, bwrap comme host).

  Les deux `{:error, _}` = échec STRUCTUREL (on n'a même pas pu trigger) → le caller (cf. `WakeRecovery`)
  re-roll/escalade. 2e voie, complémentaire de l'escalade async de la boucle (no-ACK).
  """
  @spec wake_pod(String.t()) :: :ok | {:error, :not_found | :not_a_tmux_pod}
  def wake_pod(pod_id) when is_binary(pod_id) do
    case pod_info(pod_id) do
      {:ok, %{tmux_session: session} = info} when is_binary(session) ->
        # Réveil-par-flag (rail PORTEUR) : touche `turn.flag` (`Pod.TurnFlag.touch/1` — l'I/O FS du
        # flag vit là-bas) → l'agent Monitor-armé se réveille SANS send-keys. Pas de send-keys
        # IMMÉDIAT ici → on ARME la boucle ack-driven du Pod (`:arm_kick`), qui est le FALLBACK :
        # elle send-keys `"wake"` UNIQUEMENT si le pull n'arrive pas (le flag n'a pas livré), puis
        # escalade au cap. + ré-arme la deadline de RÉPONSE. Le `wake_pod` n'est qu'un trigger
        # porteur + l'armement du filet ; le contrôle (ACK = pull) vit dans la boucle
        # (`kick_attempt`). Le knob `:wake_send_keys` (flag-only) est lu par la boucle.
        _ = Fleet.Spawner.Pod.TurnFlag.touch(info)
        _ = GenServer.cast(Fleet.Spawner.Pod.name(pod_id), :rearm_deadline)
        _ = GenServer.cast(Fleet.Spawner.Pod.name(pod_id), :arm_kick)
        :ok

      {:ok, _info} ->
        {:error, :not_a_tmux_pod}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Restart strategy d'un pod : `:temporary` pour TOUS les scopes. Le
  `DynamicSupervisor` ne ressuscite JAMAIS un pod — un
  pod mort (sortie normale OU crash) est retiré, point final. La résurrection
  est un acte délibéré du boot-orchestrator (recovery `release|recreate`).

  Les enfants `:temporary` ne comptent pas dans l'intensité
  globale `max_restarts` du supervisor → plus de cascade fleet-wide possible.
  `lifetime_scope` pilote la RECOVERY, pas le restart (la détection de
  typo de scope vit donc avec `lifetime_scope`, plus ici).
  """
  @spec restart_strategy_for(String.t() | nil) :: :temporary
  def restart_strategy_for(_scope), do: :temporary

  defp pod_child_spec(args) do
    cap_profile = args.cap_profile
    scope = Fleet.CapProfile.lifetime_scope(cap_profile)

    %{
      id: args.pod_id,
      start: {Pod, :start_link, [args]},
      restart: restart_strategy_for(scope),
      # F3 (E1) : borne du SHUTDOWN superviseur = le temps du TEARDOWN (kill tmux + rm + checkpoint
      # seed, secondes), PAS la durée de vie du pod (l'ancien `max_alive_sec * 1000` = 600s attendait
      # 10 min un pod récalcitrant à l'arrêt — config morte sans trap_exit, mur réel avec). 15s puis
      # brutal-kill OTP ; le PodWarden reape ce qui resterait.
      shutdown: 15_000,
      type: :worker
    }
  end

  defp generate_pod_id, do: UUID.uuid4()
end
