defmodule Fleet.Spawner.Pod do
  @moduledoc """
  OTP state machine for provisioning, running and releasing a pod.

  The boot sequence is `:allocating → :cleaning → :projecting → :launching →
  :monitoring`. A completed task enters `:extracting`, then releases a one-shot
  pod or returns a long-lived pod to monitoring.

  Boot work uses internal `:proceed` events, which run before external mailbox
  messages. State-entry callbacks cannot emit `:next_event`, so chained boot work
  stays in `:proceed` handlers.
  Monitoring entry subscribes to the pod topic once and arms watchdogs.
  Its response deadline is a state timeout, cancelled when monitoring is left.
  `:publishing` is a condition that gates external reset/rebrief while the pod
  remains in monitoring.

  Recovery uses `state.json` and the fleet boot epoch. Same-epoch snapshots go
  through `Pod.Recovery`; absent snapshots and snapshots from an older epoch
  allow the live-transcript/seed decision in `maybe_slot_resume/1`.
  Explicit resume options take precedence in that decision.
  """

  @behaviour :gen_statem

  require Logger

  alias Fleet.CapProfile
  alias Fleet.Event
  alias Fleet.EventRouter.Bus
  alias Fleet.Spawner.Pod.Assets
  alias Fleet.Spawner.Pod.Backend
  alias Fleet.Spawner.Pod.Brief
  alias Fleet.Spawner.Pod.CompletedPayload
  alias Fleet.Spawner.Pod.Events
  alias Fleet.Spawner.Pod.Fs
  alias Fleet.Spawner.Pod.Kick
  alias Fleet.Spawner.Pod.LaunchEnv
  alias Fleet.Spawner.Pod.LaunchSpec
  alias Fleet.Spawner.Pod.Liveness
  alias Fleet.Spawner.Pod.McpProvision
  alias Fleet.Spawner.Pod.Paths
  alias Fleet.Spawner.Pod.Publishing
  alias Fleet.Spawner.Pod.Recovery
  alias Fleet.Spawner.Pod.Scaffold
  alias Fleet.Spawner.Pod.SessionMint
  alias Fleet.Spawner.Pod.StateFs
  alias Fleet.Spawner.Pod.TaskProbe
  alias Fleet.Spawner.Pod.TurnFlag
  alias Fleet.Spawner.PodTmux
  alias Fleet.Spawner.SeedStore
  alias Fleet.SPBuilder

  @type state_name ::
          :allocating
          | :cleaning
          | :projecting
          | :launching
          | :monitoring
          | :extracting
          | :releasing

  @type condition ::
          :home_projected
          | :process_launched
          | :stream_alive
          | :output_extracted
          | :home_released
          | :publishing

  @type data :: %{
          conditions: MapSet.t(condition()),
          pod_id: String.t(),
          issue_id: String.t(),
          session_id: String.t() | nil,
          started_at: DateTime.t(),
          resume: boolean(),
          cap_profile: CapProfile.t(),
          env_vars: %{String.t() => String.t()},
          pod_dir: Path.t(),
          state_fs_path: Path.t(),
          last_error: term() | nil,
          opts: keyword(),
          port: port() | nil,
          submitted_result: map() | nil,
          extract_retries: non_neg_integer(),
          last_result: map() | nil,
          tmux_session: String.t() | nil,
          liveness_sample: term(),
          skills_paths: [Path.t()]
        }

  @doc """
  Starts the pod state machine. Called by `Fleet.Spawner.spawn_pod/3` through
  its supervisor; provisioning continues through internal events after init.
  A supplied `:slot_key` enables pool allocation and may return
  `{:error, :role_at_capacity}`.
  """
  @spec start_link(map()) :: {:ok, pid()} | :ignore | {:error, term()}
  def start_link(args) do
    # The supervisor serializes this start function through registration. Allocating
    # here avoids two concurrent callers choosing the same free slot before either
    # registers. Direct callers must provide equivalent serialization.
    case Map.get(args, :slot_key) do
      %{role: role, repo: repo} ->
        scope = CapProfile.slot_scope(args.cap_profile)

        case Fleet.Spawner.PoolSlot.allocate(role, repo, scope) do
          {:error, :role_at_capacity} = err ->
            err

          {:ok, pool} ->
            slot = %{role: role, repo: repo, pool: pool}
            args = %{args | opts: Keyword.put(args.opts, :pool, pool)}
            :gen_statem.start_link(name(args.pod_id, slot), __MODULE__, args, [])
        end

      _ ->
        :gen_statem.start_link(name(args.pod_id), __MODULE__, args, [])
    end
  end

  @doc """
  Returns the pod's Registry name for targeted calls and casts.
  """
  @spec name(String.t()) :: {:via, Registry, {Fleet.Spawner.Registry, String.t()}}
  def name(pod_id) when is_binary(pod_id) do
    {:via, Registry, {Fleet.Spawner.Registry, pod_id}}
  end

  @doc """
  Registers the pod with slot metadata `%{role, repo, pool}` so pool accounting
  can inspect allocations without calling potentially unresponsive pods.
  """
  @spec name(String.t(), map()) :: {:via, Registry, {Fleet.Spawner.Registry, String.t(), map()}}
  def name(pod_id, %{} = slot) when is_binary(pod_id) do
    {:via, Registry, {Fleet.Spawner.Registry, pod_id, slot}}
  end

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  def init(args) do
    # Trap supervisor shutdown signals so terminate/3 can release backend resources.
    Process.flag(:trap_exit, true)

    try do
      recovered = recover_or_init(args)

      start_state = Recovery.continue_to_phase(Recovery.first_continue_for(recovered))
      data = Map.drop(recovered, [:phase, :recovery])
      {:ok, start_state, data, [{:next_event, :internal, :proceed}]}
    rescue
      e -> {:stop, {e, __STACKTRACE__}}
    end
  end

  @impl :gen_statem
  def handle_event(:enter, old_state, :monitoring, data) do
    first_entry? = old_state != :extracting

    if first_entry? do
      :ok = Bus.subscribe(Bus.pod_topic(data.pod_id))

      Events.lossy_broadcast("pod.spawned", %{
        "pod_id" => data.pod_id,
        "issue_id" => data.issue_id,
        "issue" => issue_number_of(data.issue_id),
        "role" => CapProfile.name(data.cap_profile),
        "repo" => LaunchSpec.effective_project(data.opts, data.cap_profile)["repo"]
      })
    end

    actions = arm_result_deadline_actions(data)

    # Capture the Desktop slot once after launch so it can be restored on a later boot.
    actions =
      if first_entry? and LaunchSpec.remote_control?(data.cap_profile),
        do: [schedule_capture_action(0, capture_slot_first_delay_ms()) | actions],
        else: actions

    {:keep_state_and_data, actions}
  end

  def handle_event(:enter, _old_state, _state, _data), do: :keep_state_and_data

  def handle_event(:internal, :proceed, :allocating, data) do
    cap_profile_path = Path.join(data.pod_dir, ".cap-profile.json")

    with {:ok, resolved} <- safe_resolve_disallowed(data.cap_profile),
         :ok <- gate_cap_profile(resolved),
         :ok <- Fs.safe_mkdir_p(data.pod_dir),
         :ok <-
           Fs.safe_write(
             cap_profile_path,
             Jason.encode!(Map.from_struct(resolved), pretty: true)
           ) do
      {:next_state, :cleaning, data, [{:next_event, :internal, :proceed}]}
    else
      {:error, reason} -> transition_failed(data, {:allocate_failed, reason})
    end
  end

  def handle_event(:internal, :proceed, :cleaning, data) do
    # A leftover transcript would make a fresh launch reject the reused session ID.
    # Resume launches need that transcript and skip this cleanup.
    unless data.resume, do: Scaffold.gc_stale_session_jsonl(data)

    # Reset delivery acknowledgements even on resume; old flags cannot prove that
    # the new Monitor is armed or has delivered work.
    TurnFlag.reset(data.pod_dir)
    {:next_state, :projecting, data, [{:next_event, :internal, :proceed}]}
  end

  def handle_event(:internal, :proceed, :projecting, data) do
    # Resolve the catalogue after runtime configuration. Explicit nil disables skills;
    # an absent key selects the catalogue, and a path overrides it.
    skills_root =
      case Application.get_env(:lcars_fleet, :spawner_skills_root, :catalogue) do
        :catalogue -> Fleet.Catalogue.skills_root()
        other -> other
      end

    repo_md = Path.join(data.pod_dir, "CLAUDE.md.repo-source")

    # Keep .claude owned by the pod so host settings and hooks are not inherited.
    # Generated settings live separately in .lcars.
    pod_claude_dir = Path.join(data.pod_dir, ".claude")
    lcars_dir = Path.join(data.pod_dir, ".lcars")
    issues_dir = Path.join(data.pod_dir, "issues")

    warn_on_image_drift()

    with {:ok, sp_compose} <-
           SPBuilder.compose(
             data.cap_profile,
             CapProfile.active_modops(data.cap_profile),
             pod_id: data.pod_id,
             job_id: data.issue_id
           ),
         {:ok, claude_md} <-
           SPBuilder.compose_claude_md(data.cap_profile, Assets.maybe_path(repo_md)),
         {:ok, skills_paths} <- Assets.maybe_filter_skills(data.cap_profile, skills_root),
         {:ok, agent_draft} <- Assets.read_agent_draft(data.cap_profile),
         {:ok, protocole_user} <- Assets.read_protocole_user(data.cap_profile),
         :ok <- Fs.safe_mkdir_p(lcars_dir),
         :ok <- Fs.safe_mkdir_p(pod_claude_dir),
         :ok <-
           Fs.safe_write(
             Path.join(lcars_dir, "system-prompt.md"),
             sp_compose.sp_md <> "\n\n---\n\n" <> agent_draft
           ),
         :ok <- Fs.safe_write(Path.join(data.pod_dir, "CLAUDE.md"), claude_md),
         :ok <- Fs.safe_write(Path.join(lcars_dir, "protocole-user.md"), protocole_user),
         :ok <-
           Fs.safe_write(
             Path.join(lcars_dir, "settings.json"),
             Assets.pod_settings_json(data.cap_profile)
           ),
         :ok <- Fs.safe_mkdir_p(issues_dir),
         :ok <-
           Fs.safe_write(
             Path.join(issues_dir, "#{Brief.issue_id_to_filename(data.issue_id)}.md"),
             Brief.default_brief(data)
           ),
         :ok <- materialize_mandate(data),
         :ok <- Brief.maybe_enqueue_brief(data),
         {:ok, mcp_socket_path} <-
           McpProvision.ensure_pod_socket(
             data.pod_id,
             CapProfile.mcp_fleet_tools(data.cap_profile)
           ),
         :ok <-
           McpProvision.maybe_provision_mcp_config(
             data.pod_dir,
             LaunchSpec.sandbox_home(data.cap_profile, data.pod_dir),
             data.pod_id,
             mcp_socket_path,
             Backend.launch_backend()
           ),
         :ok <- Assets.provision_monitor_watch(data),
         :ok <- Scaffold.maybe_bootstrap_project_workspace(data),
         # Restore the transcript before backend launch.
         :ok <- Scaffold.maybe_recall_restore(data) do
      # Retain the socket path for liveness probes and the filtered skills for launch.
      data =
        %{add_condition(data, :home_projected) | skills_paths: skills_paths}
        |> Map.put(:mcp_socket_path, mcp_socket_path)

      {:next_state, :launching, data, [{:next_event, :internal, :proceed}]}
    else
      {:error, reason} -> transition_failed(data, {:project_failed, reason})
    end
  end

  def handle_event(:internal, :proceed, :launching, data) do
    # A crashed Pod can leave its launcher alive; reap the same pod ID before every launch.
    Backend.reap_orphan_pod(data.pod_id)
    role = cap_profile_name(data.cap_profile)
    containment = cap_profile_containment(data.cap_profile)

    launcher_path =
      if containment == "none", do: Backend.host_launch_path(), else: Backend.bwrap_launch_path()

    args = %{
      role: role,
      pod_id: data.pod_id,
      pod_dir: data.pod_dir,
      launcher_path: launcher_path,
      claude_launch_path: Backend.claude_launch_path(),
      session_id: data.session_id
    }

    case LaunchEnv.build(data, role, containment, Backend.claude_launch_path()) do
      {:ok, env} -> do_launch_backend(data, args, env)
      {:error, reason} -> transition_failed(data, reason)
    end
  end

  @extract_retry_max 5
  @extract_retry_delay_ms 1_000

  # A failed required broadcast retains the result and retries before any release or reset.
  def handle_event(:internal, :proceed, :extracting, data) do
    result = data.submitted_result || %{}

    case Events.required_broadcast("pod.completed", CompletedPayload.build(data, result)) do
      :ok ->
        do_extract_proceed(%{data | extract_retries: 0}, result)

      {:error, _reason} ->
        n = data.extract_retries

        if n >= @extract_retry_max do
          Logger.error(
            "pod #{data.pod_id} pod.completed UNDELIVERABLE after #{n} retries — result NOT delivered " <>
              "to the step_run → transition_failed (no silent wedge)"
          )

          transition_failed(data, {:pod_completed_undeliverable, n})
        else
          {:next_state, :monitoring, %{data | extract_retries: n + 1},
           [schedule_extract_retry_action()]}
        end
    end
  end

  # Checkpoint before teardown so a teardown failure does not prevent the save attempt.
  def handle_event(:internal, :proceed, :releasing, data) do
    maybe_checkpoint_seed(data)
    Backend.teardown_backend(data)
    data = add_condition(data, :home_released)
    StateFs.write_state_fs(put_phase(data, :succeeded))
    {:stop, :normal, data}
  end

  def handle_event(:internal, :proceed, _state, _data), do: :keep_state_and_data

  def handle_event({:call, from}, :info, state, data) do
    info = %{
      pod_id: data.pod_id,
      issue_id: data.issue_id,
      role: cap_profile_name(data.cap_profile),
      repo: Keyword.get(data.opts, :repo),
      project_slug: Keyword.get(data.opts, :project_slug),
      repo_id: Keyword.get(data.opts, :repo_id),
      phase: state,
      conditions: MapSet.to_list(data.conditions),
      has_active_task: TaskProbe.pod_has_active_task?(data.pod_id),
      session_id: data.session_id,
      pod_dir: data.pod_dir,
      state_fs_path: data.state_fs_path,
      last_error: data.last_error,
      last_result: data.last_result,
      tmux_session: data.tmux_session
    }

    {:keep_state_and_data, [{:reply, from, info}]}
  end

  def handle_event({:call, from}, {:refresh_work_base, project}, _state, data) do
    ws = Paths.pod_workspace_path(data.pod_dir)

    case Fleet.ProjectBootstrap.Phase.Clone.refresh_work_base(ws, project) do
      {:ok, :refreshed} ->
        Logger.info(
          "pod #{data.pod_id} refs/lcars/base REFRESHED (conflict rework — the base moved)"
        )

        {:keep_state_and_data, [{:reply, from, :ok}]}

      {:error, reason} = err ->
        Logger.error("pod #{data.pod_id} refs/lcars/base refresh FAILED: #{inspect(reason)}")
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  # Cold pipe reset is destructive and relies on the caller's :ready/:publishing gate.
  def handle_event({:call, from}, {:reprovision_pipe_workspace, project, opts}, _state, data) do
    eff_cap = CapProfile.with_project(data.cap_profile, project)

    # Update project provenance only after the disk reset succeeds.
    repinned = %{data | opts: Keyword.put(data.opts, :project, project)}

    case Fleet.ProjectBootstrap.Phase.Clone.reset_in_place(data.pod_dir, eff_cap, opts) do
      {:ok, ws, branch} ->
        # Git isolation succeeded; a failed /clear is visible but does not undo the disk reset.
        case PodTmux.send_keys(data.pod_id, "/clear") do
          :ok ->
            Logger.info(
              "pod #{data.pod_id} workspace reprovisioned COLD (#{ws} branch=#{branch}) + /clear"
            )

          {:error, reason} ->
            Logger.error(
              "pod #{data.pod_id} workspace reset COLD (#{ws} branch=#{branch}) but REPL /clear FAILED " <>
                "(#{inspect(reason)}) — REPL keeps the previous issue's context (bleed) until re-cleared"
            )
        end

        {:keep_state, repinned, [{:reply, from, :ok}]}

      {:error, reason} = err ->
        Logger.error("pod #{data.pod_id} workspace reprovision FAILED: #{inspect(reason)}")
        {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def handle_event({:call, from}, :kill, _state, data) do
    maybe_checkpoint_seed(data)
    Backend.teardown_backend(data)
    clear_pod_task(data.pod_id)
    data = add_condition(data, :home_released)
    StateFs.write_state_fs(put_phase(data, :killed))
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  def handle_event(:cast, :rearm_deadline, :monitoring, data) do
    {:keep_state_and_data, arm_result_deadline_actions(data)}
  end

  def handle_event(:cast, :rearm_deadline, _state, _data), do: :keep_state_and_data

  # Rearming the named kick timer replaces the existing loop. Allow time for flag
  # delivery before sending fallback input.
  def handle_event(:cast, :arm_kick, _state, _data) do
    {:keep_state_and_data, [schedule_kick_action(0, Kick.wake_first_delay_ms())]}
  end

  # Check task state when the deadline fires: idle pods survive; unknown state
  # re-arms the watchdogs rather than treating a failed probe as silence.
  def handle_event(:state_timeout, :result_deadline, :monitoring, data) do
    result_deadline_fire(TaskProbe.active_task_state(data.pod_id), data)
  end

  def handle_event({:timeout, :liveness}, :tick, :monitoring, data) do
    sample = Liveness.liveness_sample(data)
    moved? = Liveness.liveness_moved?(Map.get(data, :liveness_sample), sample)

    # An unobservable sample re-arms the deadline; log the measurement gap.
    if Liveness.unobservable?(sample) do
      Logger.warning(
        "pod #{data.pod_id} liveness UNOBSERVABLE this tick (every signal nil) — " <>
          "deadline re-armed (re-probe), not counted as silence"
      )
    end

    data = Map.put(data, :liveness_sample, sample)

    actions =
      if moved?,
        do: arm_result_deadline_actions(data),
        else: [liveness_tick_action(data)]

    {:keep_state, data, actions}
  end

  def handle_event({:timeout, :liveness}, :tick, _state, _data), do: :keep_state_and_data

  def handle_event({:timeout, :publish_deadline}, :fire, _state, data) do
    # An in-flight publish takes precedence over the timeout fallback.
    if Publishing.publishing?(data) and Fleet.Publish.InFlight.in_flight?(data.pod_id) do
      Logger.warning(
        "pod #{data.pod_id} :publish_deadline fired but a publish is IN FLIGHT — re-arming " <>
          "(observed live, not reset; observation over arithmetic)"
      )

      {:keep_state_and_data, [Publishing.arm_publish_deadline_action(data)]}
    else
      do_publish_deadline_lift(data)
    end
  end

  # One bounded ACK-driven loop handles bootstrap engage and wake fallback.
  def handle_event({:timeout, :kick}, {:attempt, n}, _state, %{tmux_session: session} = data)
      when is_binary(session) do
    bootstrap? = TaskProbe.no_pending_brief?(data.pod_id)
    polled = TaskProbe.polled?(data)
    cap = if bootstrap?, do: Kick.kick_bootstrap_max(), else: Kick.kick_max_attempts()

    case kick_stop_reason(data, bootstrap?, polled) do
      {:stop, pourquoi} ->
        Logger.debug("pod #{data.pod_id} #{pourquoi}")
        {:keep_state_and_data, [cancel_kick_action()]}

      :continue when n >= cap ->
        abandon_kick(data, n, bootstrap?)

      :continue ->
        kick_or_wait(data, n, kick_retry_ms(bootstrap?, polled), polled)
    end
  end

  def handle_event({:timeout, :kick}, {:attempt, _n}, _state, _data), do: :keep_state_and_data

  # Desktop slot capture is bounded and best-effort.
  def handle_event({:timeout, :capture_slot}, {:attempt, n}, :monitoring, data) do
    case SeedStore.capture_slot_bridge(data.pod_dir, data.session_id) do
      :ok ->
        Logger.debug(
          "pod #{data.pod_id} Desktop slot captured (bridge_status → sidecar) — stable on next boot"
        )

        {:keep_state_and_data, [cancel_capture_action()]}

      _not_yet ->
        if n + 1 < capture_slot_max() do
          {:keep_state_and_data, [schedule_capture_action(n + 1, capture_slot_retry_ms())]}
        else
          Logger.debug(
            "pod #{data.pod_id} Desktop slot NOT captured after #{n + 1} tries (best-effort; " <>
              "re-mint + re-capture next boot)"
          )

          {:keep_state_and_data, [cancel_capture_action()]}
        end
    end
  end

  def handle_event({:timeout, :capture_slot}, {:attempt, _n}, _state, _data),
    do: :keep_state_and_data

  def handle_event({:timeout, :extract_retry}, :fire, :monitoring, %{submitted_result: r} = data)
      when not is_nil(r),
      do: {:next_state, :extracting, data, [{:next_event, :internal, :proceed}]}

  def handle_event({:timeout, :extract_retry}, :fire, _state, _data), do: :keep_state_and_data

  # Leaving monitoring cancels its response deadline.
  def handle_event(
        :info,
        %Event{
          source: :task_queue,
          type: :"work_item.completed",
          pod_id: pid,
          payload: payload
        },
        :monitoring,
        %{pod_id: pid} = data
      ) do
    result = payload[:result] || payload["result"] || %{}

    data =
      data
      |> adopt_task_issue_id(payload)
      |> Map.put(:submitted_result, result)

    {:next_state, :extracting, data,
     [cancel_liveness_action(), {:next_event, :internal, :proceed}]}
  end

  def handle_event(
        :info,
        %Event{source: :task_queue, type: :"work_item.completed"},
        _state,
        _data
      ),
      do: :keep_state_and_data

  def handle_event(
        :info,
        %Event{type: :"deliverable.published", pod_id: pid},
        _state,
        %{pod_id: pid} = data
      ) do
    if Publishing.publishing?(data) do
      Logger.info("pod #{data.pod_id} deliverable confirmed on forge -> :ready")
    end

    {:keep_state, Publishing.leave_publishing(data),
     [Publishing.cancel_publish_deadline_action()]}
  end

  def handle_event(
        :info,
        %Event{type: :"deliverable.publish_lost", pod_id: pid} = ev,
        _state,
        %{pod_id: pid} = data
      ) do
    if Publishing.publishing?(data) do
      reason = (ev.payload || %{})["reason"] || "unknown"

      Logger.warning(
        "pod #{data.pod_id} :publishing -> :ready — completion task DIED (#{reason}); " <>
          "named-cause lift, :publish_deadline spared"
      )
    end

    {:keep_state, Publishing.leave_publishing(data),
     [Publishing.cancel_publish_deadline_action()]}
  end

  # The bus routes these events to this pod, so an unhandled event warrants a warning.
  def handle_event(:info, %Event{} = ev, state, data) do
    Logger.warning(
      "pod #{data.pod_id} received #{ev.type} on its own topic with no clause for it " <>
        "(state=#{inspect(state)}) — addressed to this pod and dropped"
    )

    :keep_state_and_data
  end

  def handle_event(:info, {port, {:exit_status, exit_code}}, _state, %{port: port} = data)
      when is_port(port) do
    if MapSet.member?(data.conditions, :output_extracted) do
      {:stop, :normal, data}
    else
      maybe_checkpoint_seed(data)
      clear_pod_task(data.pod_id)

      Events.lossy_broadcast("pod.failed", %{
        "pod_id" => data.pod_id,
        "issue_id" => data.issue_id,
        # Issue numbers need a repository to identify the downstream ticket.
        "repo" => Keyword.get(data.opts, :repo),
        "reason" => "exited_before_result",
        "exit_code" => exit_code
      })

      Logger.warning("pod #{data.pod_id} exited before submitting result (exit=#{exit_code})")

      data = Map.put(data, :last_error, {:exited_before_result, exit_code})
      StateFs.write_state_fs(put_phase(data, :failed))
      {:stop, {:shutdown, {:exited_before_result, exit_code}}, data}
    end
  end

  def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data

  @doc false
  @spec result_deadline_fire(atom(), map()) :: :gen_statem.event_handler_result(term())
  def result_deadline_fire(:active, data),
    do: transition_failed(data, {:result_timeout, data.pod_id})

  def result_deadline_fire(:idle, _data), do: :keep_state_and_data

  def result_deadline_fire(:unknown, data),
    do: {:keep_state_and_data, arm_result_deadline_actions(data)}

  # Teardown may already have run; repeated cleanup must not mask the stop reason.
  @impl :gen_statem
  def terminate(reason, _state, data) do
    Backend.teardown_backend(data)
    :ok
  rescue
    e ->
      Logger.warning(
        "pod #{Map.get(data, :pod_id)} terminate: teardown raised (non-fatal; stop=#{inspect(reason)}) — #{Exception.message(e)}"
      )

      :ok
  catch
    kind, value ->
      Logger.warning(
        "pod #{Map.get(data, :pod_id)} terminate: teardown #{kind} (non-fatal; stop=#{inspect(reason)}) — #{inspect(value)}"
      )

      :ok
  after
    McpProvision.release_pod_socket(data)
    _ = Fleet.Spawner.Pod.Egress.release(Map.get(data, :pod_id) || "")
  end

  defp kick_stop_reason(data, bootstrap?, polled) do
    cond do
      Kick.acked?(TaskProbe.brief_pulled?(data.pod_id), bootstrap?, polled) ->
        {:stop, "acked (pull/poll) → kick stopped (carrier rail takes over)"}

      # Monitor delivery is enough to stop fallback input, even without a work pull.
      # A delivered but stalled turn is handled by the liveness watchdog.
      polled and TurnFlag.delivered?(Map.get(data, :pod_dir)) ->
        {:stop,
         "wake: Monitor delivered (turn.flag == turn.flag.seen) → loop stopped, no send-keys"}

      # Bootstrap ends when the new Monitor is armed, including on resume: launch
      # clears the previous acknowledgement file.
      not polled and TurnFlag.monitor_armed?(Map.get(data, :pod_dir)) ->
        {:stop, "bootstrap: Monitor armed (turn.flag.seen) → loop stopped (rail is live)"}

      bootstrap? and not Kick.profile_send_keys?(data) ->
        {:stop, "bootstrap kick canceled (profile is flag-only, nothing pending)"}

      true ->
        :continue
    end
  end

  defp kick_retry_ms(bootstrap?, polled) do
    cond do
      bootstrap? -> Kick.kick_bootstrap_retry_ms()
      polled -> Kick.wake_retry_ms()
      true -> Kick.kick_retry_ms()
    end
  end

  defp abandon_kick(data, n, bootstrap?) do
    phase = if bootstrap?, do: :bootstrap, else: :wake

    Logger.warning(
      "pod #{data.pod_id} kick (#{phase}) abandoned after #{n} attempts — agent never acked → escalating"
    )

    {reason, reason_detail} = Event.reason_fields({:no_ack, phase})

    Events.lossy_broadcast("wake.failed", %{
      "pod_id" => data.pod_id,
      "issue_id" => data.issue_id,
      "reason" => reason,
      "reason_detail" => reason_detail,
      "pane" => PodTmux.capture_pane(data.pod_id)
    })

    {:keep_state_and_data, [cancel_kick_action()]}
  end

  # Wait for MCP activity and a live tmux session before sending input, to avoid
  # queuing duplicate commands during startup. Waiting still consumes retries.
  defp kick_or_wait(data, n, retry, polled) do
    if TaskProbe.repl_up?(data.pod_id) and PodTmux.alive?(data.pod_id) do
      _ = Kick.kick_send(data, polled)
    end

    {:keep_state_and_data, [schedule_kick_action(n + 1, retry)]}
  end

  defp materialize_mandate(%{opts: opts, pod_dir: pod_dir} = _data) do
    case Keyword.get(opts, :mandate) do
      %{ref: ref, sha: sha, ops_path: ops_path} = mandate ->
        # The task references this filename in the pod home; launch must fail if
        # the declared document cannot be copied from its pinned revision.
        filename = Map.get(mandate, :filename, "mandate.md")

        with {:ok, file} <- LaunchSpec.pin_object(ops_path, pod_dir, sha, ref),
             :ok <- File.cp(file, Path.join([pod_dir, "issues", filename])) do
          :ok
        else
          other ->
            Logger.error(
              "Pod: mandate NOT materialized (#{inspect(other)}) — the order references a file " <>
                "the pod would not have; refusing to launch a pod that cannot read its order"
            )

            {:error, {:mandate_not_materialized, other}}
        end

      _ ->
        :ok
    end
  end

  defp issue_number_of("issue-" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp issue_number_of(_), do: nil

  defp do_publish_deadline_lift(data) do
    if Publishing.publishing?(data) do
      Logger.warning(
        "pod #{data.pod_id} :publishing -> :ready by DEADLINE (deliverable.published not received in time)"
      )
    end

    {:keep_state, Publishing.leave_publishing(data),
     [Publishing.cancel_publish_deadline_action()]}
  end

  defp do_launch_backend(data, args, env) do
    with {:ok, backend} <- Backend.launch_backend_conforming(),
         {:ok, launched} when is_map(launched) <- backend.launch(args, env) do
      port = Map.get(launched, :port)
      tmux_session = Map.get(launched, :tmux_session)

      data =
        data
        |> Map.put(:port, port)
        |> Map.put(:tmux_session, tmux_session)
        |> Map.put(:session_id, data.session_id)
        |> add_condition(:process_launched)
        |> add_condition(:stream_alive)

      StateFs.write_state_fs(put_phase(data, :monitoring))

      {:next_state, :monitoring, data, brief_kick_actions(data)}
    else
      {:error, reason} -> transition_failed(data, {:launch_failed, reason})
    end
  end

  defp brief_kick_actions(%{tmux_session: nil}), do: []

  defp brief_kick_actions(%{tmux_session: session}) when is_binary(session),
    do: [schedule_kick_action(0, Kick.kick_first_delay_ms())]

  defp do_extract_proceed(data, result) do
    data =
      data
      |> Map.put(:last_result, result)
      |> add_condition(:output_extracted)

    case lifetime_scope(data.cap_profile) do
      "one-shot" ->
        {:next_state, :releasing, data, [{:next_event, :internal, :proceed}]}

      _other ->
        data =
          data
          |> Map.put(:submitted_result, nil)
          |> remove_condition(:output_extracted)

        {data, pub_actions} = Publishing.maybe_enter_publishing(data)
        {:next_state, :monitoring, data, pub_actions}
    end
  end

  defp lifetime_scope(%CapProfile{} = cp), do: CapProfile.lifetime_scope(cp)

  defp maybe_checkpoint_seed(data) do
    case LaunchSpec.rc_project(data.opts, data.cap_profile) do
      nil ->
        :ok

      project ->
        _ =
          SeedStore.checkpoint(
            data.pod_dir,
            project,
            cap_profile_name(data.cap_profile),
            data.session_id,
            checkpoint_issue(data)
          )

        :ok
    end
  end

  # Instance-scoped roles checkpoint per issue. An unparseable issue ID yields nil
  # and falls back to the per-role seed key.
  defp checkpoint_issue(data) do
    if CapProfile.slot_scope(data.cap_profile) == "instance",
      do: issue_number_of(data.issue_id)
  end

  defp recover_or_init(args) do
    base = initial_state(args)

    case File.read(base.state_fs_path) do
      {:error, :enoent} ->
        maybe_slot_resume(base)

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"session_id" => sid, "phase" => phase_str} = snap} when is_binary(sid) ->
            recover_from_snapshot(base, snap, phase_str)

          _ ->
            Logger.error(
              "pod #{base.pod_id} recover: state.json PRESENT but CORRUPT at #{base.state_fs_path} " <>
                "— fresh init (durable recovery point lost)"
            )

            base
        end

      {:error, reason} ->
        Logger.error(
          "pod #{base.pod_id} recover: state.json UNREADABLE (#{inspect(reason)}) at " <>
            "#{base.state_fs_path} — fresh init"
        )

        base
    end
  end

  # Same-epoch recovery avoids automatically replaying a session that may have
  # caused the pod failure. Older epochs allow transcript/seed reuse.
  defp recover_from_snapshot(base, snap, phase_str) do
    if Map.get(snap, "boot_id") == Fleet.Spawner.BootEpoch.id() do
      phase = Recovery.phase_from_string(phase_str) || :launching
      Recovery.apply_recovery(base, Recovery.recovery_action(phase), phase)
    else
      Logger.info(
        "pod #{base.pod_id} recover: state.json from a PREVIOUS fleet life " <>
          "(stale epoch) → unified seed decision (not a crash recovery)"
      )

      maybe_slot_resume(base)
    end
  end

  defp initial_state(args) do
    state_fs_path = Paths.state_fs_path_for(args.pod_id, args.cap_profile, args.opts)
    pod_dir = Paths.pod_dir_for(args.pod_id, args.opts)

    %{
      phase: :pending,
      conditions: MapSet.new(),
      pod_id: args.pod_id,
      issue_id: args.issue_id,
      session_id: resolve_session_id(args),
      started_at: DateTime.utc_now(),
      resume: Keyword.get(args.opts, :resume, false),
      cap_profile: args.cap_profile,
      env_vars: %{},
      pod_dir: pod_dir,
      state_fs_path: state_fs_path,
      last_error: nil,
      opts: args.opts,
      port: nil,
      submitted_result: nil,
      extract_retries: 0,
      last_result: nil,
      tmux_session: nil,
      liveness_sample: nil,
      skills_paths: []
    }
  end

  # For eligible remote-control pods, prefer an existing transcript over a captured
  # seed. Explicit resume options bypass this choice.
  defp maybe_slot_resume(base) do
    cond do
      base.resume or Keyword.has_key?(base.opts, :recall_seed_jsonl) ->
        base

      not LaunchSpec.remote_control?(base.cap_profile) ->
        base

      live_jsonl_exists?(base) ->
        %{base | resume: true}

      true ->
        case SeedStore.slot_seed(base.session_id) do
          {:ok, seed} ->
            %{base | resume: true, opts: Keyword.put(base.opts, :recall_seed_jsonl, seed)}

          :none ->
            base
        end
    end
  end

  defp live_jsonl_exists?(base) do
    cwd = LaunchSpec.pod_cwd(base.opts, base.cap_profile, base.pod_dir)

    [
      base.pod_dir,
      ".claude",
      "projects",
      SeedStore.slugify(cwd),
      "#{base.session_id}.jsonl"
    ]
    |> Path.join()
    |> File.exists?()
  end

  defp resolve_session_id(args) do
    case Keyword.get(args.opts, :session_id) do
      nil ->
        SessionMint.mint(args.cap_profile, args.opts)

      seed ->
        case Fleet.Spawner.SessionId.cast(seed) do
          {:ok, uuid} ->
            uuid

          {:error, :not_uuid_shaped} ->
            raise ArgumentError,
                  "Pod: explicit session_id #{inspect(seed)} is not a valid UUID — a recall/" <>
                    "boot seed must resume a real vendor session; refusing rather than posing a " <>
                    "non-reconstructible identity."
        end
    end
  end

  defp cap_profile_name(%CapProfile{} = cap), do: CapProfile.name(cap)

  defp cap_profile_containment(%CapProfile{} = cap), do: CapProfile.containment(cap)

  # Recovery snapshots need the state name reattached to the callback data.
  defp put_phase(data, phase), do: Map.put(data, :phase, phase)

  defp transition_failed(data, reason) do
    Logger.warning("pod #{data.pod_id} failed: #{inspect(reason)}")

    # Early failures may have no transcript; checkpointing then has nothing to save.
    maybe_checkpoint_seed(data)
    clear_pod_task(data.pod_id)
    data = Map.put(data, :last_error, reason)
    StateFs.write_state_fs(put_phase(data, :failed))

    # Normalize terms before the raw JSON websocket edge while retaining diagnostic detail.
    {category, reason_detail} = Event.reason_fields(reason)

    Events.lossy_broadcast("pod.failed", %{
      "pod_id" => data.pod_id,
      "issue_id" => data.issue_id,
      "repo" => Keyword.get(data.opts, :repo),
      "reason" => category,
      "reason_detail" => reason_detail
    })

    {:stop, {:shutdown, reason}, data}
  end

  defp add_condition(data, condition) do
    Map.update!(data, :conditions, &MapSet.put(&1, condition))
  end

  defp remove_condition(data, condition) do
    Map.update!(data, :conditions, &MapSet.delete(&1, condition))
  end

  defp clear_pod_task(pod_id) do
    Fleet.TaskQueue.clear_for_pod(pod_id)
    :ok
  rescue
    e ->
      Logger.warning("pod #{pod_id} clear_for_pod failed (non-fatal): #{inspect(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("pod #{pod_id} clear_for_pod unavailable (non-fatal): #{inspect(reason)}")
      :ok
  end

  defp arm_result_deadline_actions(data) do
    if lifetime_scope(data.cap_profile) == "forever" do
      [{:state_timeout, :infinity, :result_deadline}, {{:timeout, :liveness}, :infinity, :tick}]
    else
      [
        {:state_timeout, Liveness.monitor_timeout_ms(data), :result_deadline},
        liveness_tick_action(data)
      ]
    end
  end

  defp liveness_tick_action(data),
    do: {{:timeout, :liveness}, Liveness.liveness_tick_ms(data), :tick}

  defp cancel_liveness_action, do: {{:timeout, :liveness}, :infinity, :tick}

  # Re-briefed pipes attribute completion to the current task rather than their spawn issue.
  defp adopt_task_issue_id(data, payload) do
    case payload[:issue_id] || payload["issue_id"] do
      t when is_binary(t) and t != "" -> %{data | issue_id: t}
      _ -> data
    end
  end

  defp schedule_kick_action(n, delay), do: {{:timeout, :kick}, delay, {:attempt, n}}

  defp schedule_extract_retry_action,
    do: {{:timeout, :extract_retry}, @extract_retry_delay_ms, :fire}

  defp cancel_kick_action, do: {{:timeout, :kick}, :infinity, {:attempt, 0}}

  defp schedule_capture_action(n, delay), do: {{:timeout, :capture_slot}, delay, {:attempt, n}}
  defp cancel_capture_action, do: {{:timeout, :capture_slot}, :infinity, {:attempt, 0}}

  defp capture_slot_first_delay_ms,
    do: Application.get_env(:lcars_fleet, :spawner_capture_slot_first_delay_ms, 5_000)

  defp capture_slot_retry_ms,
    do: Application.get_env(:lcars_fleet, :spawner_capture_slot_retry_ms, 5_000)

  defp capture_slot_max, do: Application.get_env(:lcars_fleet, :spawner_capture_slot_max, 20)

  defp safe_resolve_disallowed(cap_profile) do
    {:ok, CapProfile.with_resolved_disallowed_tools(cap_profile)}
  rescue
    e -> {:error, {:baseline_corrupt, Exception.message(e)}}
  end

  # Validate the resolved profile before writing it, even when boot-time validation
  # is disabled; overlays may change containment restrictions.
  defp gate_cap_profile(resolved) do
    case CapProfile.validate(resolved) do
      :ok -> :ok
      {:error, violations} -> {:error, {:cap_profile_invalid, violations}}
    end
  end

  # Compare disk sources at each spawn to report drift from the published image
  # without changing the image used by running pods.
  defp warn_on_image_drift do
    case SPBuilder.image_drift() do
      {:ok, []} ->
        :ok

      {:ok, drifted} ->
        Logger.warning(
          "SPBuilder.Image: #{length(drifted)} prompt source(s) DIVERGE from the published epoch — " <>
            "pods keep receiving the proven-good image, the disk no longer matches it " <>
            "(restart to open a new epoch): " <>
            Enum.map_join(drifted, ", ", fn {path, how} -> "#{path} (#{how})" end)
        )

      :unpublished ->
        :ok
    end
  end
end
