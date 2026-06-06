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
  """

  alias Fleet.Spawner.Pod

  require Logger

  @doc """
  Spawn a new pod.

  ## Inputs

    * `cap_profile` — struct `%Fleet.CapProfile{}` issue de `Fleet.CapProfile.compose/2`
    * `ticket_id` — événement source (ticket Gitea, signal OS, etc.)
    * `opts` :
      * `:pod_id` (default `UUID.uuid4()`)
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

        args = %{
          cap_profile: cap_profile,
          ticket_id: ticket_id,
          pod_id: pod_id,
          opts: opts
        }

        spec = pod_child_spec(args)
        DynamicSupervisor.start_child(Fleet.Spawner.Supervisor, spec)

      {:error, _} = err ->
        err
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
  Nombre de pods actifs.
  """
  @spec count_pods() :: non_neg_integer()
  def count_pods do
    %{active: active} = DynamicSupervisor.count_children(Fleet.Spawner.Supervisor)
    active
  end

  @doc """
  Réveille un pod long-lived (lifetime_scope != one-shot) pour un nouveau
  cycle. Envoie le mot-clé `yop` via tmux send-keys au claude REPL du pod,
  déclenchant le workflow agent-worker-base :

      yop → mcp__fleet__get_task → traite → mcp__fleet__submit_result

  Pré-requis : le caller a déjà enqueué le mandat dans le broker
  `Fleet.TaskQueue` (ciblé `pod_id` ; le pod s'identifie par `_lcars_pod_id`
  sur le fil pour le récupérer via `get_task`). `wake_pod/1` ne gère QUE le
  trigger send-keys — la task
  doit être en file AVANT.

  Use-cases :
    - pipeline `standard-qa` : après findings reviewer/gatekeeper, push
      task corrective + wake_pod(engineer_pod_id) → cycle 11.0 boucle.
    - starfleet/fleet_pilot : nouveau ticket assigné au même pod long-
      lived (mandat actif) → push + wake.

  Renvoie :
    - `:ok` — send-keys exécuté.
    - `{:error, :not_found}` — pod_id inconnu (jamais spawn ou déjà kill).
    - `{:error, :not_a_tmux_pod}` — pod existe mais pas via TmuxBackend
      (LauncherPortBackend/Stub) → pas de tmux_session pour send-keys.
    - `{:error, term}` — erreur send-keys tmux (session morte côté tmux,
      etc.).
  """
  @spec wake_pod(String.t()) :: :ok | {:error, term()}
  def wake_pod(pod_id) when is_binary(pod_id) do
    case pod_info(pod_id) do
      {:ok, %{tmux_session: session} = info} when is_binary(session) ->
        # Réveil-par-flag (outil Monitor in-pod) : touche `turn.flag` → si l'agent a armé
        # son Monitor (cf. SP `agent-worker-base.md`), il se réveille SANS send-keys de
        # CONTENU (ADR-G pt3). best-effort, additif. Le `yop` reste le kick sanctionné
        # (bootstrap + fallback pods sans Monitor) ; pour un pod Monitor-armé, le yop
        # redondant retombe sur un get_task vide (done:true) — inoffensif.
        _ = touch_turn_flag(info)
        Fleet.Spawner.PodTmux.send_keys(pod_id, "yop")

      {:ok, _info} ->
        {:error, :not_a_tmux_pod}

      {:error, _} = err ->
        err
    end
  end

  # Touche le flag du monitor in-pod (`pod_dir/turn.flag`, bind-monté = `~/turn.flag` côté
  # pod). Le `watch.sh` armé via l'outil Monitor émet « ton tour » → réveille l'agent.
  defp touch_turn_flag(%{pod_dir: pod_dir}) when is_binary(pod_dir) do
    flag = Path.join(pod_dir, "turn.flag")
    _ = File.write(flag, Integer.to_string(System.system_time(:millisecond)) <> "\n")
    :ok
  rescue
    _ -> :ok
  end

  defp touch_turn_flag(_info), do: :ok

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
end
