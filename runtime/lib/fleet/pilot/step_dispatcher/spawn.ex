defmodule Fleet.Pilot.StepDispatcher.Spawn do
  @moduledoc """
  Shared issue/review spawn lifecycle and pod scope gates. Callers choose route, role
  and policy; this module materializes the order and executes lock, pod, enqueue, wake.
  Gatekeeper evaluation remains separate: it is completion-triggered, lockless and
  enqueues before spawning (see StepRunConsumer.GatekeeperEscalation).

  Capacity is checked before the label, but neither preflight nor the forge label
  reserves admission atomically. Returned errors from label/spawn/enqueue enter
  compensation; exceptions and exits are not a general rollback boundary.
  Compensation kills only when the initial observation classified the pod as absent,
  then attempts label removal and stopwatch stop. This is not proof of a fresh spawn
  or of successful cleanup. Existing pods retain their context.

  Wake errors return `{:error, {:wake_unreached, pod_id, role, reason}}` and retain
  admission. Poller counts them as started and erroneous; recovery is described at
  wake_outcome/3, not guaranteed at the next tick.
  """

  require Logger

  @in_flight_label Fleet.Labels.in_flight()

  defmodule Seams do
    @moduledoc """
    Dependencies for spawn_step/2, passed separately from the work order.
    """
    @enforce_keys [:forge, :spawner, :task_queue, :repo, :forge_opts, :wake_recovery]
    defstruct [:forge, :spawner, :task_queue, :repo, :forge_opts, :wake_recovery]

    @type t :: %__MODULE__{
            forge: module(),
            spawner: module(),
            task_queue: module(),
            repo: String.t(),
            forge_opts: keyword(),
            # Receives a respawn callback and wake options.
            wake_recovery: (String.t(), (-> any()), keyword() -> :ok | {:error, term()})
          }
  end

  defmodule Order do
    @moduledoc """
    Named work parameters keep the locked object distinct from the enqueued issue.
    Swapping these two integers would otherwise type-check but lock the wrong object.
    """
    @enforce_keys [
      :pod_id,
      :role,
      :profile,
      :brief,
      :spawn_opts,
      :lock_target,
      :issue_number,
      :log_ctx
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            pod_id: String.t(),
            role: String.t(),
            profile: Fleet.CapProfile.t(),
            # Order text, retained as content after materialization; pins travel separately.
            brief: String.t(),
            spawn_opts: keyword(),
            # Issue or PR to lock; review work locks the PR but enqueues against its parent issue.
            lock_target: integer(),
            issue_number: integer(),
            log_ctx: String.t()
          }
  end

  @doc """
  Checks liveness/capacity, materializes the order, then attempts label → stopwatch →
  spawn or reuse → enqueue → wake recovery. Reuse does not create a child.
  `Order.lock_target` can be a PR while `issue_number` identifies the enqueued issue.
  Returned pre-wake errors attempt compensation; wake errors keep admission.
  """
  @spec spawn_step(Seams.t(), Order.t()) ::
          {:ok, {:spawned, String.t(), String.t()}}
          | {:skipped, :role_at_capacity}
          | {:error, term()}
  def spawn_step(%Seams{} = seams, %Order{} = order) do
    %Seams{spawner: spawner} = seams
    %Order{pod_id: pod_id, role: role, profile: profile, spawn_opts: spawn_opts} = order

    issue_id = Fleet.Pilot.IssueId.compose(order.issue_number)
    alive_before? = pod_alive?(spawner, pod_id)

    # Query the same role/repo/scope bucket as PoolSlot allocation; saturation is a skip.
    # Reuse bypasses capacity because it creates no child. Global max_children remains
    # an error from actual spawn, not another admission policy here.
    if alive_before? or has_free_slot?(spawner, role, profile, spawn_opts) do
      locked_spawn_step(seams, order, issue_id, alive_before?)
    else
      Logger.info(
        "StepDispatcher: role bucket FULL (max_pods_per_role) → defer role=#{role} " <>
          "pod=#{pod_id} #{order.log_ctx} (no lock taken; re-dispatch when a seat frees)"
      )

      {:skipped, :role_at_capacity}
    end
  end

  # Preflight passed; materialization still precedes the forge label.
  defp locked_spawn_step(%Seams{repo: repo} = seams, %Order{} = order, issue_id, alive_before?) do
    %Order{role: role, brief: brief, spawn_opts: spawn_opts, issue_number: issue_number} = order
    # Materialize once before the label and share content/pins between spawn and enqueue.
    # Keep effective brief_kind in spawn options so completion need not rederive it.
    # BriefArtifact publication is best-effort: a local pin does not prove a remote push.
    brief_kind = Keyword.get(spawn_opts, :brief_kind, "worker")

    # Injectable ops root lets tests exercise materialization instead of only missing-worktree fallback.
    ops_root = Keyword.get(spawn_opts, :ops_root)

    case materialize_order(brief, repo, issue_number, role, brief_kind, ops_root) do
      {:error, _} = refusal ->
        refusal

      {:ok, brief, extra_opts} ->
        # Drop the caller's inline spawn copy only when an address still satisfies order_present?/1.
        # A reused pod does not rewrite its initial brief file; keeping that copy would let it
        # diverge from updated queue orders. Unpinned fallback retains the copy.
        spawn_opts =
          spawn_opts
          |> Keyword.merge(extra_opts)
          |> drop_duplicated_order(extra_opts)

        locked_spawn_step_run(
          seams,
          %Order{order | brief: brief, spawn_opts: spawn_opts},
          issue_id,
          alive_before?
        )
    end
  end

  # Use the spawner's order predicate on what remains, not only the presence of a ref.
  # Otherwise removing inline text could make the next spawn reject the materialized order.
  defp drop_duplicated_order(spawn_opts, extra_opts) do
    without_copy = Keyword.delete(spawn_opts, :brief)

    if Keyword.has_key?(extra_opts, :brief_ref) and Fleet.Spawner.order_present?(without_copy),
      do: without_copy,
      else: spawn_opts
  end

  defp materialize_order(brief, repo, issue_number, role, brief_kind, ops_root) do
    materialize_opts =
      [name_hint: "issue-#{issue_number}-#{role}", kind: brief_kind, push: :ops]
      |> then(fn o -> if ops_root, do: Keyword.put(o, :ops_root, ops_root), else: o end)

    case Fleet.Workflow.BriefArtifact.materialize(brief, repo, materialize_opts) do
      {:ok, {ref, sha}} ->
        # Queue content is the text just committed. Pins travel separately for runtime provenance;
        # do not send a command that requires mounting the entire ops tree to read one object.
        {:ok, brief, [brief_sha: sha, brief_ref: ref]}

      # Git-category failures degrade to marked inline text; the category does not prove transience.
      {:error, {:git, reason}} ->
        Logger.warning(
          "StepDispatcher: brief materialization failed transiently for #{repo}##{issue_number} " <>
            "(#{inspect(reason)}) — dispatching the INLINE order, marked unprovable"
        )

        {:ok, degraded_order(brief), []}

      # Share :pilot_require_onboarded with poller admission. When disabled, missing worktrees
      # use plain inline content; other materialization errors still refuse.
      {:error, {:work_dir_missing, _} = cause} ->
        if require_onboarded?() do
          refuse_order(repo, issue_number, role, cause)
        else
          {:ok, brief, []}
        end

      {:error, cause} ->
        refuse_order(repo, issue_number, role, cause)
    end
  end

  defp require_onboarded?, do: Application.get_env(:lcars_fleet, :pilot_require_onboarded, true)

  defp refuse_order(repo, issue_number, role, cause) do
    Logger.error(
      "StepDispatcher: REFUSING to dispatch #{repo}##{issue_number} role=#{role} — the order " <>
        "cannot be materialized (#{inspect(cause)}), and the cause is PERMANENT. Dispatching " <>
        "would produce work nobody can prove was asked for."
    )

    {:error, {:order_not_materialized, cause}}
  end

  defp degraded_order(brief) do
    "⚠ PROVENANCE ABSENTE — cet ordre n'a pas pu être commité dans le ops du projet (panne " <>
      "transitoire). Le runtime n'a donc pas de sha à graver : ce livrable ne portera pas " <>
      "d'adresse d'ordre auditable. Tu n'as rien à faire de plus — livre normalement.\n\n" <>
      brief
  end

  defp locked_spawn_step_run(
         %Seams{
           forge: forge,
           spawner: spawner,
           task_queue: task_queue,
           repo: repo,
           forge_opts: forge_opts,
           wake_recovery: wake_recovery
         },
         %Order{} = order,
         issue_id,
         alive_before?
       ) do
    %Order{
      pod_id: pod_id,
      role: role,
      profile: profile,
      brief: brief,
      spawn_opts: spawn_opts,
      lock_target: lock_target,
      issue_number: issue_number,
      log_ctx: log_ctx
    } = order

    with {:ok, _} <- forge.add_label(repo, lock_target, @in_flight_label, forge_opts),
         _ = start_stopwatch_as_role(forge, repo, lock_target, profile, forge_opts, role),
         {:ok, _} <- maybe_spawn(spawner, alive_before?, profile, issue_id, spawn_opts),
         :ok <-
           enqueue_brief(
             task_queue,
             pod_id,
             role,
             issue_id,
             {repo, issue_number, lock_target},
             brief,
             spawn_opts
           ) do
      # Preserve the recovery result: admission remains even when wake fails.
      # The caller must count the typed wake error rather than report a clean spawn.
      wake_recovery.(
        pod_id,
        fn -> maybe_spawn(spawner, false, profile, issue_id, spawn_opts) end,
        wake_fun: fn p -> safe_wake(spawner, p) end
      )
      |> wake_outcome(order, alive_before?)
    else
      {:error, _} = err ->
        # This branch also handles a failed add_label before any pod spawn.
        # Initial liveness controls the kill attempt; its result is intentionally discarded.
        _ = if not alive_before?, do: safe_kill(spawner, pod_id)

        # Report removal's result. Reconciliation depends on observed ownership and successful
        # later reads/writes; the log's fixed two-tick recovery claim is not guaranteed.
        lock_state =
          case forge.remove_label(repo, lock_target, @in_flight_label, forge_opts) do
            {:ok, _} ->
              "lock removed"

            other ->
              "lock removal FAILED (#{inspect(other)}) — issue stays lcars-in-flight, " <>
                "Poller reconciliation reclaims (≤2 ticks)"
          end

        # Stop with the same role identity even when the preceding attempt failed.
        _ = stop_stopwatch_as_role(forge, repo, lock_target, profile, forge_opts, role)

        Logger.warning(
          "StepDispatcher: dispatch role=#{role} pod=#{pod_id} #{log_ctx} → #{inspect(err)} " <>
            "(#{lock_state}#{if(alive_before?, do: "", else: ", pod killed")} — re-dispatch on next tick)"
        )

        compensated_verdict(err)
    end
  end

  # Forge time belongs to the authenticated role; start and stop must use that identity.
  # No declared identity skips the metric. Missing required credentials warn at start.
  # Returned metric failures are ignored; exceptions are not caught by these wrappers.
  defp start_stopwatch_as_role(forge, repo, lock_target, profile, forge_opts, role) do
    case forge_identity_or_none(profile, forge_opts, role) do
      {:ok, ro} ->
        forge.start_stopwatch(repo, lock_target, ro)

      :no_identity ->
        :ok

      {:error, :role_token_unavailable} ->
        Logger.warning(
          "StepDispatcher: no forge token for role #{inspect(role)} — stopwatch NOT " <>
            "started on #{repo}##{lock_target} (the ticket will not show the worker " <>
            "arriving; check the role account/token provisioning)"
        )
    end
  end

  # Same identity as the start — Gitea accepts the stop ONLY from the user who started it.
  defp stop_stopwatch_as_role(forge, repo, lock_target, profile, forge_opts, role) do
    with {:ok, ro} <- forge_identity_or_none(profile, forge_opts, role) do
      forge.stop_stopwatch(repo, lock_target, ro)
    end
  end

  # A role-capacity race becomes a skip after attempted compensation, even if cleanup failed.
  # Other errors, including global :max_children, remain errors.
  defp compensated_verdict({:error, :role_at_capacity}), do: {:skipped, :role_at_capacity}
  defp compensated_verdict(err), do: err

  defp maybe_spawn(_spawner, true = _alive?, _profile, _issue_id, _spawn_opts),
    do: {:ok, :rebriefed}

  defp maybe_spawn(spawner, false = _alive?, profile, issue_id, spawn_opts) do
    case spawner.spawn_pod(profile, issue_id, spawn_opts) do
      {:ok, _pid} -> {:ok, :spawned}
      {:error, _} = err -> err
    end
  end

  defp wake_outcome(:ok, %Order{} = order, alive_before?) do
    Logger.info(
      "StepDispatcher: #{disposition(alive_before?)} role=#{order.role} pod=#{order.pod_id} " <>
        "#{order.log_ctx}"
    )

    {:ok, {:spawned, order.pod_id, order.role}}
  end

  # Keep lock, pod and queued brief after failed wake. This dispatcher does not periodically re-wake.
  # Poller reconciliation uses @pulled_states: an unpulled pending task owns no lock.
  # After suspect observations and successful reclaim, dispatch can resume; no one-tick guarantee.
  defp wake_outcome({:error, reason}, %Order{} = order, alive_before?) do
    Logger.warning(
      "StepDispatcher: #{disposition(alive_before?)} role=#{order.role} pod=#{order.pod_id} " <>
        "#{order.log_ctx} BUT wake UNREACHABLE → #{inspect(reason)} (lock+brief kept, re-wake on " <>
        "next tick ; tally = error, not silently dispatched)"
    )

    {:error, {:wake_unreached, order.pod_id, order.role, reason}}
  end

  defp disposition(true = _alive_before?), do: "re-briefed (pod alive, context kept)"
  defp disposition(false = _alive_before?), do: "spawned"

  # The pod pulls the prepared order through TaskQueue/get_work_item; raw issue text would
  # bypass judge framing. metadata.issue keeps the parent issue correlation.
  #
  # When the lock sits on a PR (review, rework), the task says so: its pod may be named after the
  # issue (`…-issue-7-engineer` reworking PR #8), and reconciliation reads lock ownership from the
  # ASSIGNED task — otherwise a live rework loses its PR lock as an orphan within two ticks.
  defp enqueue_brief(
         task_queue,
         pod_id,
         role,
         issue_id,
         {repo, number, lock_target},
         payload,
         spawn_opts
       ) do
    # Queue the final content, with pins in separate fields; do not reconstruct an ops-path instruction.
    attrs = %{
      issue_id: issue_id,
      role: role,
      brief: payload,
      brief_ref: Keyword.get(spawn_opts, :brief_ref),
      brief_sha: Keyword.get(spawn_opts, :brief_sha),
      metadata: lock_metadata(%{"issue" => number}, repo, number, lock_target)
    }

    case task_queue.enqueue(pod_id, attrs) do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp lock_metadata(meta, _repo, number, number), do: meta

  defp lock_metadata(meta, repo, _number, pr),
    do: Map.merge(meta, %{"repo" => repo, "lock_pr" => pr})

  defp safe_wake(spawner, pod_id) do
    if Fleet.Opts.exported?(spawner, :wake_pod, 1), do: spawner.wake_pod(pod_id), else: :ok
  rescue
    e ->
      # Returned exception evidence lets WakeRecovery retry or escalate; it is not a successful wake.
      Logger.warning(
        "StepDispatcher: safe_wake — wake_pod RAISED for #{inspect(pod_id)} (#{inspect(e)}) → {:error}"
      )

      {:error, {:wake_raised, pod_id}}
  end

  @doc """
  Attempts kill once, returning :ok, the returned error, :unsupported for a missing
  capability, or a classified unexpected-result/raised-exception error. Exits and
  throws propagate. Callers choose whether to use the result; this helper neither
  checks prior existence nor schedules cleanup or retry.
  """

  @spec safe_kill(module(), String.t()) :: :ok | :unsupported | {:error, term()}
  def safe_kill(spawner, pod_id) do
    if Fleet.Opts.exported?(spawner, :kill_pod, 1) do
      case spawner.kill_pod(pod_id) do
        :ok -> :ok
        {:error, _} = err -> err
        other -> {:error, {:unexpected_kill_result, other}}
      end
    else
      :unsupported
    end
  rescue
    e -> {:error, {:kill_raised, Exception.message(e)}}
  end

  # No declared forge identity is distinct from unavailable credentials.
  defp forge_identity_or_none(profile, forge_opts, role) do
    if Fleet.CapProfile.forge_identity?(profile) do
      Fleet.Forge.Client.as_role(forge_opts, role)
    else
      :no_identity
    end
  end

  # Missing capacity capability or raised check allows admission; PoolSlot still enforces allocation.
  # Query scope through the profile accessor so preflight and allocation use the same bucket.
  defp has_free_slot?(spawner, role, profile, spawn_opts) do
    not Fleet.Opts.exported?(spawner, :has_free_slot?, 3) or
      spawner.has_free_slot?(
        role,
        Keyword.get(spawn_opts, :repo_id),
        Fleet.CapProfile.slot_scope(profile)
      )
  rescue
    e ->
      Logger.warning(
        "StepDispatcher: has_free_slot? RAISED (#{inspect(e)}) → assume a seat " <>
          "(fail-open; PoolSlot.allocate/3 still enforces)"
      )

      true
  end

  # An observed live pod is reused. Missing pod_info capability selects fresh spawn.
  defp pod_alive?(spawner, pod_id) do
    Fleet.Opts.exported?(spawner, :pod_info, 1) and
      case spawner.pod_info(pod_id) do
        {:ok, _} -> true
        # Unreachable may still be alive: avoid replacing a possibly living pod.
        {:error, :unreachable} -> true
        {:error, _} -> false
      end
  rescue
    e ->
      # A raised probe conservatively selects reuse; unexpected case results are caught here too.
      Logger.warning(
        "StepDispatcher: pod_alive? — pod_info RAISED for #{inspect(pod_id)} (#{inspect(e)}) → assume ALIVE (fail-closed)"
      )

      true
  end

  @doc """
  Project scope uses one id per repository/role; instance scope uses an issue-based id.
  This helper does not construct the separate PR ids used by review callers.
  Only the two supported scope strings have clauses.
  """
  @spec pod_id_for_scope(String.t(), String.t(), integer(), String.t()) :: String.t()
  def pod_id_for_scope("project", repo, _number, role),
    do: Fleet.PodId.for_repo(repo, role)

  def pod_id_for_scope("instance", repo, number, role),
    do: Fleet.PodId.for_issue(repo, number, role)

  @doc """
  Checks pod state before costly project resolution. One-shot lifetime proceeds directly.
  For context-long lifetimes, busy or uncertain state defers. An absent pod proceeds;
  a ready instance-scoped pod preserves its ticket context, while a ready project-scoped
  pod requests reprovision for a potentially different ticket.

  Callers must provide scope explicitly and run maybe_reprovision/5 after resolution.
  This observation is not a reservation: state may change before the action.
  """
  @spec project_scope_decision(String.t(), module(), String.t(), String.t()) ::
          :proceed | :role_busy | :ready_needs_reprovision
  def project_scope_decision("one-shot", _spawner, _pod_id, _slot), do: :proceed

  # Instance context belongs to the same ticket through rework; do not reset it as if switching subjects.
  def project_scope_decision(_context_long, spawner, pod_id, "instance") do
    case pipe_rebrief_state(spawner, pod_id) do
      :busy -> :role_busy
      _dead_or_ready -> :proceed
    end
  end

  def project_scope_decision(_context_long, spawner, pod_id, _project) do
    case pipe_rebrief_state(spawner, pod_id) do
      :dead -> :proceed
      :busy -> :role_busy
      :ready -> :ready_needs_reprovision
    end
  end

  @doc """
  Turns :role_busy into a skip before project resolution; every other value passes.
  """
  @spec gate_scope_decision(:proceed | :role_busy | :ready_needs_reprovision) ::
          :ok | {:skipped, :role_busy}
  def gate_scope_decision(:role_busy), do: {:skipped, :role_busy}
  def gate_scope_decision(_proceed_or_reprovision), do: :ok

  @doc """
  For :ready_needs_reprovision, attempts workspace reset with the resolved project pin
  and issue slug; returned reset errors defer. :proceed does nothing.
  Missing project or reset capability also proceeds without a reset guarantee.
  """
  @spec maybe_reprovision(
          :proceed | :ready_needs_reprovision,
          module(),
          String.t(),
          map() | nil,
          String.t()
        ) :: :ok | {:skipped, :role_busy}
  def maybe_reprovision(:ready_needs_reprovision, spawner, pod_id, project, slug),
    do: reprovision_then_proceed(spawner, pod_id, project, slug)

  def maybe_reprovision(:proceed, _spawner, _pod_id, _project, _slug), do: :ok

  # Ready means no active task and no :publishing flag. It does not prove confirmed publication:
  # a publish deadline can clear the flag too. See Pod's reprovision/deadline handlers.
  defp pipe_rebrief_state(spawner, pod_id) do
    case safe_pod_info(spawner, pod_id) do
      {:ok, %{conditions: conds, has_active_task: active}} ->
        cond do
          active -> :busy
          :publishing in conds -> :busy
          true -> :ready
        end

      # Partial information conservatively defers rather than permitting reset.
      {:ok, _partial} ->
        :busy

      # Unknown from timeout or raised probe defers; it must not permit replacing a possibly live pod.
      :unknown ->
        :busy

      # Other returned values or missing capability classify as absent, not only :not_found.
      :error ->
        :dead
    end
  end

  defp safe_pod_info(spawner, pod_id) do
    if Fleet.Opts.exported?(spawner, :pod_info, 1) do
      case spawner.pod_info(pod_id) do
        {:ok, info} -> {:ok, info}
        {:error, :unreachable} -> :unknown
        _ -> :error
      end
    else
      :error
    end
  rescue
    e ->
      # Raised probes become unknown; exits/throws are not caught here.
      Logger.warning(
        "StepDispatcher: safe_pod_info — pod_info RAISED for #{inspect(pod_id)} (#{inspect(e)}) → :unknown (fail-closed defer)"
      )

      :unknown
  end

  @doc """
  Refreshes a reused pod's lcars/base without clearing its ticket context. Cold
  reprovision supplies its own base refresh; :not_found permits a later fresh clone.
  Returned refresh errors defer. Missing project/capability skips the operation;
  raised exceptions and unexpected results are not handled here.
  """
  @spec refresh_conflict_base(
          :proceed | :ready_needs_reprovision,
          module(),
          String.t(),
          map() | nil
        ) :: :ok | {:skipped, :stale_base_unrefreshed}
  def refresh_conflict_base(:ready_needs_reprovision, _spawner, _pod_id, _project), do: :ok

  def refresh_conflict_base(:proceed, spawner, pod_id, project) do
    if is_map(project) and Fleet.Opts.exported?(spawner, :refresh_work_base, 2) do
      case spawner.refresh_work_base(pod_id, project) do
        :ok -> :ok
        # Not registered = fresh spawn ahead: it pins its own base at clone.
        {:error, :not_found} -> :ok
        {:error, _} -> {:skipped, :stale_base_unrefreshed}
      end
    else
      :ok
    end
  end

  defp reprovision_then_proceed(spawner, pod_id, project, slug) do
    if is_map(project) and Fleet.Opts.exported?(spawner, :reprovision_pipe_workspace, 3) do
      case spawner.reprovision_pipe_workspace(pod_id, project, slug: slug) do
        :ok -> :ok
        {:error, _} -> {:skipped, :role_busy}
      end
    else
      :ok
    end
  end

  # Human pod labels use Fleet.Layout.pod_label/3, also shared with spawner-side callers.

  @doc """
  Sanitizes the issue title into an ASCII local-branch slug, truncated to 40 characters.
  Empty results become work. This is naming, not redaction or a uniqueness guarantee.
  """
  @spec feature_slug(map()) :: String.t()
  def feature_slug(issue) do
    (issue["title"] || "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "work"
      s -> s
    end
  end

  # Route updates two coupled keys; single optional keys use Fleet.Opts.maybe_put/3.

  @doc "Puts `:workflow_map`/`:step` into the spawn_opts if the route is present (nil = no-op)."
  @spec maybe_put_route(keyword(), {String.t(), String.t()} | nil) :: keyword()
  def maybe_put_route(spawn_opts, nil), do: spawn_opts

  def maybe_put_route(spawn_opts, {workflow_map_name, step}),
    do: spawn_opts |> Keyword.put(:workflow_map, workflow_map_name) |> Keyword.put(:step, step)

  @doc """
  Returns the raw forge repository id, or nil on a returned lookup error.
  SessionMint/SessionId enforce the decimal repository segment's 0..9999 bound;
  do not fold ids with modulo, which would collide identities across repositories.
  Missing ids remain an error for project-bound minting, not a random-id fallback.
  """
  @spec resolve_repo_id(module(), String.t(), keyword()) :: non_neg_integer() | nil
  def resolve_repo_id(forge, repo, forge_opts) do
    case Fleet.Forge.repo_id(forge, repo, forge_opts) do
      {:ok, id} -> id
      {:error, _reason} -> nil
    end
  end

  @doc """
  Normalizes the shared forge route read: a route stays a tuple, :none becomes nil,
  and returned errors remain errors. Unexpected shapes raise.
  """
  @spec route_for(module(), String.t(), integer(), keyword()) ::
          {:ok, {String.t(), String.t()} | nil} | {:error, term()}
  def route_for(forge, repo, number, forge_opts) do
    case forge.get_route(repo, number, forge_opts) do
      {:ok, {_p, _s} = route} -> {:ok, route}
      :none -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end
end
