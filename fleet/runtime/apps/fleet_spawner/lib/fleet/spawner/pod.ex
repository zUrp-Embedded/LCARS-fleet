defmodule Fleet.Spawner.Pod do
  @moduledoc """
  GenServer state machine du cycle 8 phases ALLOCATE → RELEASE pour un pod.

  ## Phases

      :pending → :allocating → :cleaning → :projecting → :injecting →
      :launching → :monitoring → :extracting → :releasing → :succeeded
                                                          ↓
                                                        :failed

  Chaque transition est dirigée par `handle_continue/2`. L'`init/1`
  démarre la chaîne avec `{:continue, :allocate}`. Si recovery state
  FS détecte un `session_id` capturé, l'`init/1` reprend directement
  en phase `:launching` (le respawn passera `--resume <session_id>`).

  ## Conditions

  Set d'événements observables ajoutés au passage des phases :
  `:home_projected`, `:context_injected`, `:process_launched`,
  `:stream_alive`, `:init_validated`, `:output_extracted`,
  `:home_released`. Permet à `pod_info/1` de distinguer "phase X
  atteinte" de "condition Y vérifiée".

  ## F-INIT-VALIDATE (handoff consultant SDK)

  Au passage `:monitoring`, le module valide les 9 champs critiques
  de la première frame `init` NDJSON émise par claude -p :
  `tools`, `model`, `permission_mode`, `api_key_source`, `cwd`,
  `claude_code_version`, `mcp_servers`, `slash_commands`, `agents`.
  Si la frame `init` reçue manque > 0 champs requis ou si
  `api_key_source` ≠ `"oauth"`, le pod transitionne `:failed`.

  ## Recovery state FS

  `<state_fs_root>/<scope>/<id>/state.json` écrit après `:launching`
  (capture `session_id`). `<scope>` ∈ `pods` (one-shot) /
  `pipes` (pipe) / `runs` (run/session-user/forever). Au prochain
  `init/1`, lecture du fichier → reprise directe en phase
  `:launching` avec le `session_id` (claude -p `--resume`).
  """

  use GenServer, restart: :transient

  require Logger

  alias Fleet.Credentials
  alias Fleet.EventRouter.Bus
  alias Fleet.SPBuilder
  alias Fleet.Spawner.Pod.InitValidator

  @type phase ::
          :pending
          | :allocating
          | :cleaning
          | :projecting
          | :injecting
          | :launching
          | :monitoring
          | :extracting
          | :releasing
          | :succeeded
          | :failed
          | :unknown

  @type condition ::
          :home_projected
          | :context_injected
          | :process_launched
          | :stream_alive
          | :init_validated
          | :output_extracted
          | :home_released

  @type state :: %{
          phase: phase(),
          conditions: MapSet.t(condition()),
          pod_id: String.t(),
          ticket_id: String.t(),
          session_id: String.t() | nil,
          cap_profile: Fleet.CapProfile.t(),
          env_vars: %{String.t() => String.t()},
          ndjson_log_path: Path.t() | nil,
          pod_dir: Path.t(),
          state_fs_path: Path.t(),
          init_message: map() | nil,
          last_error: term() | nil,
          opts: keyword(),
          # #593 D11 — Port stream lifecycle (post-init events + exit).
          port: port() | nil,
          # Buffer accumulé entre chunks Port (binary, split sur "\n").
          event_buffer: binary(),
          # Dernier event "result" reçu (claude one-shot final, ou nil).
          last_result: map() | nil
        }

  # ============================================================
  # Public API
  # ============================================================

  @doc """
  Démarre un Pod GenServer pour un nouveau pod éphémère.

  Invoqué par `Fleet.Spawner.spawn_pod/3` via le child_spec passé à
  `DynamicSupervisor.start_child/2`. L'`init/1` enchaîne ensuite
  les phases via `handle_continue/2`.
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args.pod_id))
  end

  @doc """
  Renvoie le nom registry-via du Pod GenServer pour un `pod_id`.

  Utilisé pour `GenServer.call` ciblé + `kill_pod` lookup
  (`Fleet.Spawner.Registry`).
  """
  @spec name(String.t()) :: {:via, Registry, {Fleet.Spawner.Registry, String.t()}}
  def name(pod_id) when is_binary(pod_id) do
    {:via, Registry, {Fleet.Spawner.Registry, pod_id}}
  end

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(args) do
    state = recover_or_init(args)
    {:ok, state, {:continue, first_continue_for(state)}}
  end

  @impl GenServer
  def handle_continue(:allocate, state), do: do_allocate(state)
  def handle_continue(:clean, state), do: do_clean(state)
  def handle_continue(:project, state), do: do_project(state)
  def handle_continue(:inject, state), do: do_inject(state)
  def handle_continue(:launch, state), do: do_launch(state)
  def handle_continue(:monitor, state), do: do_monitor(state)
  def handle_continue(:extract, state), do: do_extract(state)
  def handle_continue(:release, state), do: do_release(state)

  @impl GenServer
  def handle_call(:info, _from, state) do
    info = %{
      pod_id: state.pod_id,
      ticket_id: state.ticket_id,
      phase: state.phase,
      conditions: MapSet.to_list(state.conditions),
      session_id: state.session_id,
      pod_dir: state.pod_dir,
      state_fs_path: state.state_fs_path,
      last_error: state.last_error,
      init_message: state.init_message,
      last_result: state.last_result
    }

    {:reply, info, state}
  end

  # ============================================================
  # #593 D11 — handle_info Port lifecycle
  # ============================================================
  #
  # PortBackend.launch ouvre `Port.open` (sous le process Pod) et bloque
  # jusqu'à la 1ʳᵉ frame `init` NDJSON. Après, le Pod reprend la main
  # (handle_continue :monitor → :extract → :release → :succeeded). Le
  # Port n'est PAS fermé : claude continue à streamer (assistant events,
  # result event final, exit_status). Sans clause handle_info, ces
  # messages tombent dans le default → log unexpected message, state
  # machine ne note JAMAIS la complétion réelle.
  #
  # Format Port options actuelles (PortBackend ligne 47-53) : `:binary`
  # + `:exit_status`, PAS `{:line, _}` ni `{:packet, :line}` → on reçoit
  # `{port, {:data, binary_chunk}}` (multi-events ou partial), buffering
  # + split sur "\n" requis.

  @impl GenServer
  def handle_info({port, {:data, chunk}}, %{port: port} = state)
      when is_port(port) and is_binary(chunk) do
    {events, buffer} = parse_chunks(state.event_buffer <> chunk)
    new_state = Enum.reduce(events, %{state | event_buffer: buffer}, &handle_event/2)
    {:noreply, new_state}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state)
      when is_port(port) do
    # Broadcast pod.terminated (catalogue events.yaml). Stop normal :
    # le DynamicSupervisor (restart: :transient) ne respawnera pas.
    safe_broadcast("pod.terminated", %{
      "pod_id" => state.pod_id,
      "ticket_id" => state.ticket_id,
      "exit_code" => exit_code,
      "had_result" => not is_nil(state.last_result)
    })

    Logger.info(
      "pod #{state.pod_id} terminated exit=#{exit_code} " <>
        "had_result=#{not is_nil(state.last_result)}"
    )

    {:stop, :normal, state}
  end

  # Catch-all silencieux : autres messages (down, monitor, etc.) ignorés.
  def handle_info(_other, state), do: {:noreply, state}

  # ============================================================
  # Event stream parser (NDJSON chunks → events)
  # ============================================================

  # Split binary sur "\n", retourne {lines_décodées, buffer_residual}.
  # Lignes vides ou JSON invalide → ignorées silencieusement (stream
  # claude peut contenir des fragments non-NDJSON, robustesse).
  defp parse_chunks(buffer) do
    parts = String.split(buffer, "\n")
    {lines, [residual]} = Enum.split(parts, length(parts) - 1)

    events =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, ev} when is_map(ev) -> [ev]
          _ -> []
        end
      end)

    {events, residual}
  end

  # Dispatch par type d'event NDJSON claude (stream-json).
  defp handle_event(%{"type" => "system", "subtype" => "init"}, state) do
    # Déjà consommé sync par PortBackend.launch → no-op idempotent
    # (claude ne réémet pas, mais defensive).
    state
  end

  defp handle_event(%{"type" => "result", "is_error" => false} = result, state) do
    safe_broadcast("pod.completed", %{
      "pod_id" => state.pod_id,
      "ticket_id" => state.ticket_id,
      "result" => result
    })

    %{state | last_result: result}
  end

  defp handle_event(%{"type" => "result", "is_error" => true} = result, state) do
    safe_broadcast("pod.failed", %{
      "pod_id" => state.pod_id,
      "ticket_id" => state.ticket_id,
      "result" => result
    })

    %{state | last_result: result}
  end

  defp handle_event(%{"type" => "assistant"}, state) do
    # Assistant turns intermédiaires : tracking possible (latency, token
    # count). D11 minimal : no-op, hook potentiel pour PipelineConsumer
    # Sprint 2 #583.
    state
  end

  defp handle_event(_other, state), do: state

  # Broadcast Bus avec rescue : un crash event_router (bus down, atom
  # invalide) ne doit JAMAIS faire crash le Pod GenServer.
  defp safe_broadcast(event_type, payload) do
    Bus.broadcast(event_type, payload)
  rescue
    e ->
      Logger.warning(
        "Pod safe_broadcast #{event_type} rescue (non-fatal) — " <>
          Exception.message(e)
      )

      :ok
  end

  # ============================================================
  # Phases
  # ============================================================

  defp do_allocate(state) do
    File.mkdir_p!(state.pod_dir)

    cap_profile_path = Path.join(state.pod_dir, ".cap-profile.json")
    File.write!(cap_profile_path, Jason.encode!(Map.from_struct(state.cap_profile), pretty: true))

    new_state = %{state | phase: :cleaning}
    {:noreply, new_state, {:continue, :clean}}
  end

  defp do_clean(state) do
    # POD_DIR vient d'être créé en :allocate ; rien à clean ici tant que
    # le respawn (recovery) ne réutilise pas le même path.
    new_state = %{state | phase: :projecting}
    {:noreply, new_state, {:continue, :project}}
  end

  defp do_project(state) do
    skills_root = Application.get_env(:fleet_spawner, :skills_root, nil)
    repo_md = Path.join(state.pod_dir, "CLAUDE.md.repo-source")

    sp_dir = Path.join(state.pod_dir, ".claude")
    File.mkdir_p!(sp_dir)

    with {:ok, sp_compose} <-
           SPBuilder.compose(state.cap_profile, [], pod_id: state.pod_id, job_id: state.ticket_id),
         {:ok, claude_md} <- SPBuilder.compose_claude_md(state.cap_profile, maybe_path(repo_md)),
         {:ok, _skills_paths} <- maybe_filter_skills(state.cap_profile, skills_root) do
      File.write!(Path.join(sp_dir, "system-prompt.md"), sp_compose.sp_md)
      File.write!(Path.join(sp_dir, "CLAUDE.md"), claude_md)

      brief_dir = Path.join(state.pod_dir, "context")
      File.mkdir_p!(brief_dir)
      File.write!(Path.join(brief_dir, "brief.md"), default_brief(state))

      new_state =
        state
        |> Map.put(:phase, :injecting)
        |> add_condition(:home_projected)

      {:noreply, new_state, {:continue, :inject}}
    else
      {:error, reason} -> transition_failed(state, {:project_failed, reason})
    end
  end

  defp do_inject(state) do
    role = Map.get(state.cap_profile.metadata, "name", "engineer")

    case Credentials.resolve_env(role, state.cap_profile) do
      {:ok, env_vars} ->
        new_state =
          state
          |> Map.put(:phase, :launching)
          |> Map.put(:env_vars, env_vars)
          |> add_condition(:context_injected)

        {:noreply, new_state, {:continue, :launch}}

      {:error, reason} ->
        transition_failed(state, {:credentials_resolve_failed, reason})
    end
  end

  defp do_launch(state) do
    role = Map.get(state.cap_profile.metadata, "name", "engineer")
    budget_sec = get_in(state.cap_profile.spec, ["budget", "maxDurationSec"]) || 600

    budget_usd =
      get_in(state.cap_profile.spec, ["budget", "maxUsd"])
      |> case do
        nil -> "1.0"
        v -> to_string(v)
      end

    args = %{
      role: role,
      pod_id: state.pod_id,
      pod_dir: state.pod_dir,
      budget_sec: budget_sec,
      budget_usd: budget_usd,
      bwrap_launch_path: bwrap_launch_path(),
      claude_launch_path: claude_launch_path(),
      session_id: state.session_id
    }

    env = Map.merge(state.env_vars, skills_plugins_env(state.cap_profile))

    case launch_backend().launch(args, env) do
      {:ok, %{init_message: init_msg, ndjson_log: ndjson_log} = launched} ->
        # #593 D11 — extract port (PortBackend l'inclut, StubBackend non).
        # nil-able : tests stub n'ont pas de Port → handle_info clauses
        # ne matchent jamais → comportement legacy préservé.
        port = Map.get(launched, :port)

        new_state =
          state
          |> Map.put(:phase, :monitoring)
          |> Map.put(:init_message, init_msg)
          |> Map.put(:ndjson_log_path, ndjson_log)
          |> Map.put(:port, port)
          |> Map.put(
            :session_id,
            init_msg["session_id"] || launched[:session_id] || state.session_id
          )
          |> add_condition(:process_launched)
          |> add_condition(:stream_alive)

        write_state_fs(new_state)
        {:noreply, new_state, {:continue, :monitor}}

      {:error, reason} ->
        transition_failed(state, {:launch_failed, reason})
    end
  end

  defp do_monitor(state) do
    # F-INIT-VALIDATE : validation locale via InitValidator (9 champs init NDJSON +
    # api_key_source == "oauth" G24 invariant). Note : Fleet.Credentials.PlanValidator.validate_plan/1
    # (chantier 3) valide le plan SDK Pro/Max via account_info — sémantique différente,
    # à intégrer en complément post-chantier 8 fleet_claude_bridge (placeholder
    # :not_wired_yet actuellement).
    case InitValidator.validate(state.init_message, state.cap_profile) do
      :ok ->
        new_state =
          state
          |> Map.put(:phase, :extracting)
          |> add_condition(:init_validated)

        {:noreply, new_state, {:continue, :extract}}

      {:error, reason} ->
        transition_failed(state, {:init_validation_failed, reason})
    end
  end

  defp do_extract(state) do
    new_state =
      state
      |> Map.put(:phase, :releasing)
      |> add_condition(:output_extracted)

    {:noreply, new_state, {:continue, :release}}
  end

  defp do_release(state) do
    new_state =
      state
      |> Map.put(:phase, :succeeded)
      |> add_condition(:home_released)

    write_state_fs(new_state)
    {:noreply, new_state}
  end

  # ============================================================
  # Recovery / state FS
  # ============================================================

  defp recover_or_init(args) do
    base = initial_state(args)

    case File.read(base.state_fs_path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"session_id" => session_id, "phase" => phase}} when is_binary(session_id) ->
            base
            |> Map.put(:session_id, session_id)
            |> Map.put(:phase, phase_from_string(phase) || :launching)

          _ ->
            base
        end

      {:error, _} ->
        base
    end
  end

  defp first_continue_for(%{phase: :pending}), do: :allocate
  defp first_continue_for(%{phase: :launching}), do: :launch
  defp first_continue_for(%{phase: phase}), do: phase_to_continue(phase)

  defp phase_to_continue(:allocating), do: :allocate
  defp phase_to_continue(:cleaning), do: :clean
  defp phase_to_continue(:projecting), do: :project
  defp phase_to_continue(:injecting), do: :inject
  defp phase_to_continue(:launching), do: :launch
  defp phase_to_continue(:monitoring), do: :monitor
  defp phase_to_continue(:extracting), do: :extract
  defp phase_to_continue(:releasing), do: :release
  defp phase_to_continue(_), do: :allocate

  defp phase_from_string(s) when is_binary(s) do
    s
    |> String.to_existing_atom()
    |> case do
      atom when is_atom(atom) -> atom
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp phase_from_string(_), do: nil

  defp initial_state(args) do
    state_fs_path = state_fs_path_for(args.pod_id, args.cap_profile, args.opts)
    pod_dir = pod_dir_for(args.pod_id, args.opts)

    %{
      phase: :pending,
      conditions: MapSet.new(),
      pod_id: args.pod_id,
      ticket_id: args.ticket_id,
      session_id: nil,
      cap_profile: args.cap_profile,
      env_vars: %{},
      ndjson_log_path: nil,
      pod_dir: pod_dir,
      state_fs_path: state_fs_path,
      init_message: nil,
      last_error: nil,
      opts: args.opts,
      port: nil,
      event_buffer: "",
      last_result: nil
    }
  end

  defp pod_dir_for(pod_id, opts) do
    base =
      Keyword.get(
        opts,
        :pod_dir_root,
        Application.get_env(:fleet_spawner, :pod_dir_root, "/tmp/lcars-pods")
      )

    Path.join(base, "pod-#{pod_id}")
  end

  defp state_fs_path_for(pod_id, cap_profile, opts) do
    root =
      Keyword.get(
        opts,
        :state_fs_root,
        Application.get_env(:fleet_spawner, :state_fs_root, "/var/lib/lcars")
      )

    scope = scope_for(get_in(cap_profile.spec, ["invocation", "lifetime_scope"]))
    Path.join([root, scope, pod_id, "state.json"])
  end

  defp scope_for("pipe"), do: "pipes"
  defp scope_for("run"), do: "runs"
  defp scope_for("session-user"), do: "runs"
  defp scope_for("forever"), do: "runs"
  defp scope_for(_), do: "pods"

  defp write_state_fs(state) do
    File.mkdir_p!(Path.dirname(state.state_fs_path))

    payload = %{
      "v" => 1,
      "pod_id" => state.pod_id,
      "ticket_id" => state.ticket_id,
      "session_id" => state.session_id,
      "phase" => Atom.to_string(state.phase)
    }

    tmp = state.state_fs_path <> ".tmp"
    File.write!(tmp, Jason.encode!(payload, pretty: true))
    File.rename!(tmp, state.state_fs_path)
    :ok
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp transition_failed(state, reason) do
    Logger.warning("pod #{state.pod_id} failed: #{inspect(reason)}")

    new_state =
      state
      |> Map.put(:phase, :failed)
      |> Map.put(:last_error, reason)

    write_state_fs(new_state)
    {:stop, {:shutdown, reason}, new_state}
  end

  defp add_condition(state, condition) do
    Map.update!(state, :conditions, &MapSet.put(&1, condition))
  end

  defp maybe_path(path) do
    if File.exists?(path), do: path, else: nil
  end

  defp maybe_filter_skills(_cap_profile, nil), do: {:ok, []}

  defp maybe_filter_skills(cap_profile, root) do
    Fleet.SPBuilder.filter_skills(cap_profile, root)
  end

  @doc false
  # DN ring1/pod-bootstrap-superpowers : LCARS_SKILLS_PLUGINS = noms
  # plugins uniques extraits des skills QUALIFIÉS `plugin:skill` du
  # cap-profile.spec.knowledge.skills. Consommé par bin/bwrap_launch.sh
  # (mount-bind RO). Anti-M1 : un skill non-qualifié (sans `:`) n'est
  # PAS un plugin → filtré. Vide → pas d'env var (rétro-compatible).
  # Public @doc false : pure, testable directement (pas d'intégration
  # mock-backend lourde pour de la logique triviale).
  def skills_plugins_env(%Fleet.CapProfile{spec: spec}) do
    plugins =
      (spec || %{})
      |> Map.get("knowledge", %{})
      |> Kernel.||(%{})
      |> Map.get("skills", [])
      |> Kernel.||([])
      |> Enum.filter(&(is_binary(&1) and String.contains?(&1, ":")))
      |> Enum.map(&(&1 |> String.split(":", parts: 2) |> hd()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case plugins do
      [] -> %{}
      list -> %{"LCARS_SKILLS_PLUGINS" => Enum.join(list, " ")}
    end
  end

  defp default_brief(state) do
    """
    # Brief — pod #{state.pod_id}

    Ticket : #{state.ticket_id}
    """
  end

  defp launch_backend do
    Application.get_env(
      :fleet_spawner,
      :launch_backend,
      Fleet.Spawner.LaunchBackend.PortBackend
    )
  end

  defp bwrap_launch_path do
    Application.get_env(:fleet_spawner, :bwrap_launch_path, "/usr/local/bin/bwrap_launch.sh")
  end

  defp claude_launch_path do
    Application.get_env(:fleet_spawner, :claude_launch_path, "/usr/local/bin/claude_launch.sh")
  end
end
