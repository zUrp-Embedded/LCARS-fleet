defmodule Fleet.Spawner do
  @moduledoc """
  Pilote lifecycle pod LCARS v2 (Ring 1 pod primitive).

  Spawne, surveille et termine les pods agents éphémères selon le
  cycle 8 phases canon (ALLOCATE → CLEAN → PROJECT → INJECT → LAUNCH
  → MONITOR → EXTRACT → RELEASE). Chaque pod = un `Fleet.Spawner.Pod`
  GenServer supervisé par `Fleet.Spawner.Supervisor`.

  ## API

    * `spawn_pod/3` — démarre un nouveau pod
    * `kill_pod/1` — termine un pod par son ID
    * `pod_info/1` — retourne l'état courant d'un pod
    * `count_pods/0` — nombre de pods actifs

  ## Restart strategy

  Tous les pods sont `:temporary` (DN-recovery option B, 2026-06-06, cf.
  `restart_strategy_for/1`). Le `DynamicSupervisor` ne ressuscite JAMAIS un pod —
  un pod mort (normal OU crash) est retiré, point. `lifetime_scope` pilote
  désormais la RECOVERY (`release|recreate|resume`), pas le restart.

  ## Recovery

  State FS minimal `<state_fs_root>/{pipes,runs,pods}/<id>/state.json` =
  **snapshot d'observation** (où en était le pod), pas un état de reconstruction.
  La résurrection est un acte **délibéré** du boot-orchestrator qui re-matérialise
  depuis le desired-state (cap-profile), via `--resume <session_id>` si la session
  est reprenable (PoC-19, contexte préservé serveur Anthropic). Cf.
  `DN-recovery-2026-06-06`.

  ## Q4 ADR-B random pod_id

  Génération `UUID.uuid4()` côté caller (collision-free statistique
  sans coordinateur central).

  ## Exit codes

    * `{:ok, pid}` — pod démarré
    * `{:error, :cap_profile_invalid, reason}` — struct invalide
    * `{:error, {:already_started, pid}}` — pod_id collision
    * `{:error, :invalid_pod_id}` — pod_id non path-safe (hors `[A-Za-z0-9._-]` ou contient `..`) — F076
    * `{:error, :mandate_required}` — pod one-shot sans mandat (R18)
  """

  alias Fleet.Spawner.Pod

  require Logger

  @doc """
  Spawn a new pod.

  ## Inputs

    * `cap_profile` — struct `%Fleet.CapProfile{}` issue de `Fleet.CapProfile.compose/2`
    * `ticket_id` — événement source (ticket Gitea, signal OS, etc.)
    * `opts` :
      * `:pod_id` (default `UUID.uuid4()`) — doit être **path-safe** (`[A-Za-z0-9._-]`, pas de `..`),
        car interpolé dans des paths FS (`~/pods/pod_<id>`, sock, state recovery) ;
        sinon `{:error, :invalid_pod_id}` (F076).
      * `:state_fs_root` (override, default config `:fleet_spawner, :state_fs_root`)
      * `:mandate` — le travail du pod (string). R18 : **obligatoire** pour un
        pod `one-shot` (sinon `{:error, :mandate_required}`).
      * `:allow_no_mandate` — échappatoire admin/diagnostic (bool, default false).
  """
  @spec spawn_pod(Fleet.CapProfile.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_pod(%Fleet.CapProfile{} = cap_profile, ticket_id, opts \\ [])
      when is_binary(ticket_id) and is_list(opts) do
    case mandate_guard(cap_profile, opts) do
      :ok ->
        pod_id = Keyword.get_lazy(opts, :pod_id, &generate_pod_id/0)

        # F076 : pod_id file dans des paths FS (pod_dir `~/pods/pod_<id>`, sock_path, state recovery)
        # par interpolation. Défaut UUID = sûr, mais l'override `:pod_id` (stage `issue-N-role-ts`, role
        # résolu forge ; permanent `permanent-<name>-ts` ; admin) n'était PAS validé → un `/` ou `..`
        # traverserait hors de `~/pods`. Guard charset path-safe + rejet `..` → refus CLAIR, jamais un
        # path traversé (tous les pod_id légitimes — UUID / catalogue / stage — passent).
        if valid_pod_id?(pod_id) do
          # BL-055 — id pod DÉTERMINISTE : un re-dispatch retombe sur le même `pod_id`. Si une
          # TOMBSTONE terminale (`state.json` :succeeded/:released/:killed) d'un cycle précédent
          # subsiste, `recover_or_init` la lirait → `:release` → stop MUET sans launch → boucle
          # orphelin côté poller. On efface la tombstone (state + pod_dir) AVANT spawn → init FRESH.
          # No-op si pas de snapshot / snapshot en vol (recovery :resume/:recreate intacte).
          _ = Fleet.Spawner.Pod.clear_terminal_snapshot(pod_id, cap_profile, opts)

          args = %{
            cap_profile: cap_profile,
            ticket_id: ticket_id,
            pod_id: pod_id,
            opts: opts
          }

          spec = pod_child_spec(args)
          DynamicSupervisor.start_child(Fleet.Spawner.Supervisor, spec)
        else
          {:error, :invalid_pod_id}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  #pod-seed v4 — RECALL délibéré : ramène vivant l'agent `(projet, role)` depuis son seed checkpointé
  (`projects.work/<projet>/pods/`). Lit la carte (uuid+jsonl), spawn un pod en mode resume :
  `session_id` = l'uuid du seed, `resume: true`, le seed est restauré dans le pod AVANT le launch
  (do_project → maybe_recall_restore) → claude `--resume <uuid>` reprend le contexte. Nom Desktop
  `<projet>_<role>`. `allow_no_mandate` (le pod resume son contexte, pas idle ; pas de mandat neuf).

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
            allow_no_mandate: true
          )
        end
    end
  end

  # R18 (verrou I-CBC) : un pod `one-shot` (1 tâche puis meurt) DOIT porter un
  # mandat — sinon il part sans travail (brief générique → claude attend →
  # timeout). Les pods long-lived (`forever`/`run`/`pipe`) pullent leurs tâches
  # via MCP (`yop` → get_task) → exemptés (épargne les pods permanents/gatekeeper).
  # Échappatoire admin/diagnostic explicite : `opts[:allow_no_mandate]`.
  defp mandate_guard(%Fleet.CapProfile{spec: spec}, opts) do
    mandate = Keyword.get(opts, :mandate)
    # `nil` ET `""` (mandat vide — ex. `StageSpawner.build_mandate` sur un
    # stage_ctx vide/malformé) comptent tous deux comme « pas de mandat ».
    has_mandate? = is_binary(mandate) and mandate != ""
    scope = get_in(spec, ["invocation", "lifetime_scope"])

    cond do
      has_mandate? ->
        :ok

      Keyword.get(opts, :allow_no_mandate, false) ->
        :ok

      scope == "one-shot" ->
        # Diagnosable (pas un refus muet) : distingue clairement le cas.
        Logger.warning(
          "Fleet.Spawner.spawn_pod refusé (R18) : pod one-shot sans mandat — " <>
            "fournir :mandate (le travail) ou :allow_no_mandate (admin/diagnostic)."
        )

        {:error, :mandate_required}

      is_nil(scope) ->
        # Profil sans lifetime_scope déclaré (non validé ?) : exemption par défaut
        # (on ne refuse que le one-shot EXPLICITE), mais on rend le trou visible.
        Logger.warning(
          "Fleet.Spawner.spawn_pod (R18) : lifetime_scope absent du cap-profile — " <>
            "spawn autorisé sans mandat (exemption par défaut, profil à vérifier)."
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
        # LIFE-003 (DN-recovery B §5) : release DÉLIBÉRÉE d'abord — handle_call(:kill)
        # fait teardown backend + clear_for_pod + état terminal :killed, puis stop.
        # Fallback brutal terminate_child SEULEMENT si le pod ne répond pas (timeout
        # / déjà mort). Plus de bypass de la transition de release.
        try do
          :ok = GenServer.call(pid, :kill, 5_000)
          :ok
        catch
          :exit, _reason ->
            DynamicSupervisor.terminate_child(Fleet.Spawner.Supervisor, pid)
            :ok
        end

      [] ->
        {:error, :not_found}
    end
  end

  # Convention #596 (R2) : le workspace livrable d'un pod = `<pod_dir>/workspace` (sous `$POD_DIR`,
  # bound bwrap RW). Sous-dossier centralisé ICI — autorité unique de la convention de placement.
  # F121 : `Pod` (maybe_put_pod_cwd + pod.completed) le dérive via `pod_workspace_path/1`, plus de
  # littéral recopié. `ProjectBootstrap.Clone` garde sa copie (ring1 ne peut pas dépendre de spawner
  # sans cycle spawner⇄bootstrap) MAIS il RETOURNE le workspace calculé → producteur autoritaire.
  @pod_workspace_subdir "workspace"

  @doc """
  Workspace livrable depuis un `pod_dir` DÉJÀ connu (`<pod_dir>/workspace`). Pur — pour les
  appelants intra-app qui tiennent le pod_dir (ex. `Pod` sur son state) au lieu de ré-encoder le
  littéral `"workspace"` (F121 : autorité unique #596 R2). `pod_workspace_dir/1` reste la voie
  registry (le monde lit où IL a placé le pod, Q2 anti-I-CBC).
  """
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Path.join(pod_dir, @pod_workspace_subdir)

  @doc """
  Résout le workspace livrable d'un pod (`<pod_dir>/workspace`) depuis le pod_dir ENREGISTRÉ (#596 R3).
  Le monde lit où IL a placé le pod (record spawner via `pod_info`), pas une assertion du pod (Q2 :
  anti-I-CBC — le pod ne nomme jamais le chemin de son propre audit). Sert à l'Executor pour gater le
  workspace en mode `git_native`.
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
        # `kill_pod/1` ; supprime une race exposée par le stop rapide de LIFE-003).
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
  Énumère les `:info` des pods vivants — **read seam observabilité** (BL-026).

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

  **Rail porteur = réveil-par-flag** (`turn.flag` + outil Monitor in-pod), touché ICI. Déclenche le workflow
  agent-worker-base :

      (flag touché → Monitor « ton tour ») → mcp__fleet__get_task → traite → mcp__fleet__submit_result

  #5.2 — `wake_pod` n'est QUE *trigger + armement du filet* : il touche le flag (porteur), puis ARME (cast)
  la boucle ack-driven du Pod (`:arm_kick` — le FALLBACK : send-keys `"wake"` UNIQUEMENT si le pull n'arrive
  pas) + ré-arme la deadline de RÉPONSE (`:rearm_deadline`, F112). Il ne fait **plus** de send-keys lui-même.

  Pré-requis : le caller a déjà enqueué le mandat dans `Fleet.TaskQueue` (ciblé `pod_id` ; le pod s'identifie
  par `_lcars_pod_id` sur le fil) AVANT l'appel. Le CONTENU passe TOUJOURS par MCP (`get_task`), jamais par
  le texte injecté.

  Use-cases :
    - pipeline `standard-qa` : après findings reviewer/gatekeeper, push task corrective + wake_pod(eng) ;
    - starfleet/fleet_pilot : nouveau ticket assigné au même pod long-lived → push + wake.

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
        # Réveil-par-flag (rail PORTEUR) : touche `turn.flag` → l'agent Monitor-armé se réveille SANS
        # send-keys (ADR-G pt3). #5.2 [3b] : plus de send-keys IMMÉDIAT ici → on ARME la boucle ack-driven
        # du Pod (`:arm_kick`), qui est le FALLBACK : elle send-keys `"wake"` UNIQUEMENT si le pull n'arrive
        # pas (le flag n'a pas livré), puis escalade au cap. + ré-arme la deadline de RÉPONSE (F112). Le
        # `wake_pod` n'est plus qu'un trigger porteur + l'armement du filet ; le contrôle (ACK = pull) vit
        # dans la boucle (`kick_attempt`). Le knob `:wake_send_keys` (flag-only) est désormais lu par la boucle.
        _ = touch_turn_flag(info)
        _ = GenServer.cast(Fleet.Spawner.Pod.name(pod_id), :rearm_deadline)
        _ = GenServer.cast(Fleet.Spawner.Pod.name(pod_id), :arm_kick)
        :ok

      {:ok, _info} ->
        {:error, :not_a_tmux_pod}

      {:error, _} = err ->
        err
    end
  end

  # Touche le flag du monitor in-pod (`pod_dir/turn.flag`, bind-monté = `~/turn.flag` côté
  # pod). Le `watch.sh` armé via l'outil Monitor émet « ton tour » → réveille l'agent.
  defp touch_turn_flag(%{pod_dir: pod_dir}) when is_binary(pod_dir), do: write_turn_flag(pod_dir)
  defp touch_turn_flag(_info), do: :ok

  @doc false
  # Écrit un token UNIQUE dans `pod_dir/turn.flag`. watch.sh compare le CONTENU (`cur != last`) : un ms BARE
  # peut se répéter (2 wakes même ms) → token identique → wake MANQUÉ ; le suffixe unique garantit que chaque
  # écriture change le contenu → toujours détectée. `File.write` RENVOIE `{:error,_}` (ne lève PAS) sur dir
  # disparu/perm/disque → on traite le RETOUR (le `_ =` l'avalait). Rail PORTEUR : flag muet = log-LOUD
  # (best-effort : fallback send-keys + result_deadline rattrapent, jamais avalé). Public (`@doc false`) pour
  # le test : le chemin "proceed" (tmux_session) n'est jamais atteint par StubBackend.
  def write_turn_flag(pod_dir) when is_binary(pod_dir) do
    flag = Path.join(pod_dir, "turn.flag")

    token =
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}"

    case File.write(flag, token <> "\n") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "write_turn_flag #{pod_dir}: écriture flag échouée (#{inspect(reason)}) — rail porteur muet (best-effort)"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "write_turn_flag #{pod_dir}: exception écriture flag (#{inspect(e)}) — rail porteur muet (best-effort)"
      )

      :ok
  end

  @doc """
  Restart strategy d'un pod : `:temporary` pour TOUS les scopes (DN-recovery,
  option B 2026-06-06). Le `DynamicSupervisor` ne ressuscite JAMAIS un pod — un
  pod mort (sortie normale OU crash) est retiré, point final. La résurrection
  est un acte délibéré du boot-orchestrator (recovery `release|recreate|resume`).

  Ferme le 73e : les enfants `:temporary` ne comptent pas dans l'intensité
  globale `max_restarts` du supervisor → plus de cascade fleet-wide possible.
  `lifetime_scope` pilote désormais la RECOVERY, pas le restart (la détection de
  typo de scope vit donc avec `lifetime_scope`, plus ici).
  """
  @spec restart_strategy_for(String.t() | nil) :: :temporary
  def restart_strategy_for(_scope), do: :temporary

  defp pod_child_spec(args) do
    cap_profile = args.cap_profile
    scope = Fleet.CapProfile.lifetime_scope(cap_profile)
    max_alive_sec = get_in(cap_profile.spec, ["invocation", "max_alive_sec"]) || 600

    %{
      id: args.pod_id,
      start: {Pod, :start_link, [args]},
      restart: restart_strategy_for(scope),
      shutdown: max_alive_sec * 1000,
      type: :worker
    }
  end

  defp generate_pod_id, do: UUID.uuid4()

  # F076 : pod_id path-safe (interpolé dans pod_dir / sock_path / state recovery — cf. Pod.pod_dir_for).
  # Charset blanc [A-Za-z0-9._-] (couvre UUID, `permanent-<name>-<ts>`, `issue-<n>-<role>-<ts>`) + rejet
  # explicite de `..` (seul construct traversal qui passerait le charset ; `/` est déjà hors charset).
  defp valid_pod_id?(id) when is_binary(id),
    do: Regex.match?(~r/^[A-Za-z0-9._-]+$/, id) and not String.contains?(id, "..")

  defp valid_pod_id?(_), do: false
end
