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

  Mappée depuis `cap_profile.spec["invocation"]["lifetime_scope"]` :

    * `"one-shot"` → `:temporary` (pas de restart, mort propre post-EXTRACT)
    * `"pipe"` / `"run"` → `:transient` (restart si crash, pas si exit normal)
    * `"forever"` → `:permanent` (daemon long-run, restart toujours)

  ## Recovery

  State FS minimal `<state_fs_root>/{pipes,runs,pods}/<id>/state.json`
  écrit aux transitions critiques. Au respawn, `init/1` du Pod
  GenServer lit ce fichier et reprend via `--resume <session_id>`
  (PoC-19, conversation préservée serveur Anthropic).

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
        DynamicSupervisor.terminate_child(Fleet.Spawner.Supervisor, pid)

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
      [{pid, _}] -> {:ok, GenServer.call(pid, :info)}
      [] -> {:error, :not_found}
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
      {:ok, %{tmux_session: session}} when is_binary(session) ->
        Fleet.Spawner.PodTmux.send_keys(pod_id, "yop")

      {:ok, _info} ->
        {:error, :not_a_tmux_pod}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Mappe `lifetime_scope` cap-profile vers OTP restart strategy.
  """
  @spec restart_strategy_for(String.t()) :: :temporary | :transient | :permanent
  def restart_strategy_for("one-shot"), do: :temporary
  def restart_strategy_for(scope) when scope in ["pipe", "run"], do: :transient
  def restart_strategy_for("forever"), do: :permanent

  # finding Vulcan : un lifetime_scope inconnu (typo) tombait SILENCIEUSEMENT sur :temporary
  # (pas de restart). On garde le défaut sûr mais on le rend VISIBLE (typo non masquée).
  def restart_strategy_for(other) do
    Logger.warning(
      "Fleet.Spawner.restart_strategy_for: lifetime_scope inconnu #{inspect(other)} → :temporary (défaut — typo cap-profile ?)"
    )

    :temporary
  end

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
