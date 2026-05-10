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
    * `"pipe"` / `"run"` / `"session-user"` → `:transient` (restart si crash, pas si exit normal)
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

  @doc """
  Spawn a new pod.

  ## Inputs

    * `cap_profile` — struct `%Fleet.CapProfile{}` issue de `Fleet.CapProfile.compose/2`
    * `ticket_id` — événement source (ticket Gitea, signal OS, etc.)
    * `opts` :
      * `:pod_id` (default `UUID.uuid4()`)
      * `:state_fs_root` (override, default config `:fleet_spawner, :state_fs_root`)
  """
  @spec spawn_pod(Fleet.CapProfile.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_pod(%Fleet.CapProfile{} = cap_profile, ticket_id, opts \\ [])
      when is_binary(ticket_id) and is_list(opts) do
    pod_id = Keyword.get_lazy(opts, :pod_id, &generate_pod_id/0)

    args = %{
      cap_profile: cap_profile,
      ticket_id: ticket_id,
      pod_id: pod_id,
      opts: opts
    }

    spec = pod_child_spec(args)
    DynamicSupervisor.start_child(Fleet.Spawner.Supervisor, spec)
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
  Mappe `lifetime_scope` cap-profile vers OTP restart strategy.
  """
  @spec restart_strategy_for(String.t()) :: :temporary | :transient | :permanent
  def restart_strategy_for("one-shot"), do: :temporary
  def restart_strategy_for(scope) when scope in ["pipe", "run", "session-user"], do: :transient
  def restart_strategy_for("forever"), do: :permanent
  def restart_strategy_for(_), do: :temporary

  defp pod_child_spec(args) do
    cap_profile = args.cap_profile
    scope = get_in(cap_profile.spec, ["invocation", "lifetime_scope"]) || "one-shot"
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
