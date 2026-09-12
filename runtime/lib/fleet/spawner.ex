defmodule Fleet.Spawner do
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.PodId,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Catalogue,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.CapProfile,
      Fleet.SPBuilder,
      Fleet.Credentials,
      Fleet.EventRouter,
      Fleet.ProjectBootstrap,
      Fleet.TaskQueue,
      Fleet.Shutdown.Quiesce,
      Fleet.PeriodicCheck,
      Fleet.Grace,
      Fleet.Publish.InFlight
    ],
    exports: [Application, PermanentBoot, PodTmux, Pod.McpProvision, LaunchBackend]

  @moduledoc """
  API for starting, inspecting, waking and terminating agent pods.

  Each pod runs as a `Fleet.Spawner.Pod` under `Fleet.Spawner.Supervisor`.
  Children are temporary: restarting a dead pod requires an explicit spawn.
  Session recovery is handled by `Fleet.Spawner.Pod`.
  """

  alias Fleet.CapProfile
  alias Fleet.Spawner.Pod

  require Logger

  @doc """
  Returns whether a pod ID is safe for paths, sockets and session names.

  IDs are 1–100 characters, start alphanumeric, use `[A-Za-z0-9._-]`, and exclude `..`.
  """
  @spec valid_pod_id?(term()) :: boolean()
  def valid_pod_id?(id) when is_binary(id),
    do:
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/, id) and
        not String.contains?(id, "..")

  def valid_pod_id?(_), do: false

  @doc """
  Returns whether the profile explicitly declares `one-shot` and therefore requires a brief.

  A missing scope returns false here; `spawn_pod/3` rejects it before consulting this predicate.
  """
  @spec brief_required?(CapProfile.t()) :: boolean()
  def brief_required?(%CapProfile{spec: spec}) do
    get_in(spec, ["invocation", "lifetime_scope"]) == "one-shot"
  end

  @doc """
  Checks for a non-empty binary `:brief` or a binary `:brief_ref`.

  Shared by spawn admission and dispatch when omitting the inline brief copy.
  This checks presence only; it does not resolve the reference or deliver work.
  """
  @spec order_present?(keyword()) :: boolean()
  def order_present?(opts) when is_list(opts) do
    brief = Keyword.get(opts, :brief)
    (is_binary(brief) and brief != "") or is_binary(Keyword.get(opts, :brief_ref))
  end

  @doc """
  Returns whether a role declares a business capability.

  This cross-boundary resolver fails closed when the role's profile cannot be loaded.
  """
  @spec role_has_capability?(String.t(), atom() | String.t()) :: boolean()
  def role_has_capability?(role, cap) when is_binary(role) do
    case CapProfile.load(role) do
      {:ok, profile} -> CapProfile.has_capability?(profile, cap)
      _ -> false
    end
  end

  @doc """
  Starts a pod from a capability profile and a source issue/event identifier.

  Options used for admission and identity:

    * `:pod_id` — defaults to a UUID; must satisfy `valid_pod_id?/1`.
      Reusing an ID permits recovery of its persisted state.
    * `:rc_name` — a display label; requires a valid `:project_slug` unless
      `:pod_id` identifies a fleet permanent.
    * `:repo_id` — repository identity used for pool allocation and session minting.
    * `:brief` / `:brief_ref` — inline file copy or materialized order reference.
      One-shot profiles require `order_present?/1` unless `:allow_no_brief` is true.
      This diagnostic bypass defaults to `false`.
    * `:state_fs_root` — overrides `:lcars_fleet, :spawner_state_fs_root`.

  Refuses admission during fleet shutdown, for missing profile lifetime/interlocutor,
  invalid IDs/projects, missing orders or incomplete terminal-state cleanup.
  Capacity and process-start errors are returned as `{:error, reason}`.
  `{:ok, pid}` means the process started; provisioning and backend launch follow
  through internal events and can still fail.
  """
  @spec spawn_pod(CapProfile.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def spawn_pod(%CapProfile{} = cap_profile, issue_id, opts \\ [])
      when is_binary(issue_id) and is_list(opts) do
    # A struct alone does not guarantee the required profile fields are present.
    with :ok <- quiesce_guard(),
         {:ok, _scope} <- CapProfile.fetch_lifetime_scope(cap_profile),
         {:ok, _who} <- CapProfile.fetch_interlocutor(cap_profile),
         :ok <- project_guard(opts),
         :ok <- brief_guard(cap_profile, opts) do
      pod_id = Keyword.get_lazy(opts, :pod_id, &generate_pod_id/0)

      # Validate before using the caller-supplied ID in filesystem paths.
      if valid_pod_id?(pod_id),
        do: spawn_after_tombstone_clear(cap_profile, issue_id, pod_id, opts),
        else: {:error, :invalid_pod_id}
    else
      {:error, :no_lifetime_scope} ->
        Logger.error(
          "Spawner: spawn_pod refused — cap-profile has no lifetime_scope (schema-required; " <>
            "an unvalidated/hand-forged struct is not a spawnable state)."
        )

        {:error, :cap_profile_no_lifetime_scope}

      {:error, :no_interlocutor} ->
        Logger.error(
          "Spawner: spawn_pod refused — cap-profile has no interlocutor (schema-required; " <>
            "the protocol contract a pod is provisioned with is never inferred)."
        )

        {:error, :cap_profile_no_interlocutor}

      {:error, _} = err ->
        err
    end
  end

  # Clear terminal state before reusing an ID, otherwise same-epoch recovery would
  # release the new pod without launching it. Abort if cleanup is incomplete.
  defp spawn_after_tombstone_clear(cap_profile, issue_id, pod_id, opts) do
    case Fleet.Spawner.Pod.StateFs.clear_terminal_snapshot(pod_id, cap_profile, opts) do
      :ok ->
        spawn_pod_child(cap_profile, issue_id, pod_id, opts)

      {:error, _reasons} ->
        Logger.error(
          "Spawner: spawn_pod refused for #{pod_id} — a terminal tombstone survives its erase " <>
            "(see errors above). Starting would produce a pod that releases without working."
        )

        {:error, :terminal_tombstone_not_cleared}
    end
  end

  defp spawn_pod_child(cap_profile, issue_id, pod_id, opts) do
    args = %{
      cap_profile: cap_profile,
      issue_id: issue_id,
      pod_id: pod_id,
      slot_key: %{role: CapProfile.name(cap_profile), repo: Keyword.get(opts, :repo_id)},
      opts: opts
    }

    spec = pod_child_spec(args)

    case DynamicSupervisor.start_child(Fleet.Spawner.Supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      :ignore -> {:error, :pod_init_ignored}
      {:error, _} = err -> err
    end
  end

  @doc """
  Resumes a project's role from its checkpointed seed, using the resolved profile.

  Instance-scoped roles require an issue number; project-scoped roles reject one.
  Returns `{:error, :no_seed}` when no checkpoint exists, or the spawn result.
  The saved transcript is restored before launching with its session UUID.
  """
  @spec recall(String.t(), String.t(), pos_integer() | nil) :: {:ok, pid()} | {:error, term()}
  def recall(project, role, issue \\ nil)
      when is_binary(project) and is_binary(role) and (is_nil(issue) or is_integer(issue)) do
    # Resolve overlays before choosing the seed key, which depends on the profile.
    with {:ok, cap_profile} <- CapProfile.resolve(CapProfile, role),
         :ok <- recall_key_guard(cap_profile, role, issue),
         {:ok, %{uuid: uuid, jsonl: jsonl}} <-
           seed_or_error(Fleet.Spawner.SeedStore.read_map(project, role, issue)) do
      spawn_pod(cap_profile, "recall-#{project}-#{role}",
        pod_id: "recall-#{project}-#{role}",
        session_id: uuid,
        resume: true,
        recall_seed_jsonl: jsonl,
        rc_name: Fleet.Layout.pod_label(project, role),
        project_slug: project,
        allow_no_brief: true
      )
    end
  end

  defp seed_or_error(:none), do: {:error, :no_seed}
  defp seed_or_error({:ok, _} = ok), do: ok

  defp recall_key_guard(cap_profile, role, issue) do
    case {CapProfile.slot_scope(cap_profile), issue} do
      {"instance", nil} -> {:error, {:ticket_required, role}}
      {"project", n} when is_integer(n) -> {:error, {:ticket_not_applicable, role}}
      _ -> :ok
    end
  end

  defp quiesce_guard do
    if Fleet.Shutdown.Quiesce.quiescing?(), do: {:error, :fleet_quiescing}, else: :ok
  end

  defp project_guard(opts) do
    named? = is_binary(Keyword.get(opts, :rc_name))
    project = Keyword.get(opts, :project_slug)

    cond do
      not named? ->
        :ok

      # Fleet permanents have no project; recognize them by their pod ID.
      match?(
        {:ok, _},
        Fleet.Spawner.PermanentBoot.parse_permanent(Keyword.get(opts, :pod_id, ""))
      ) ->
        :ok

      is_binary(project) and Fleet.Slug.valid?(project) ->
        :ok

      true ->
        Logger.warning(
          "Spawner: spawn_pod refused: named pod without a valid :project — " <>
            "rc_name=#{inspect(Keyword.get(opts, :rc_name))} project=#{inspect(project)}. " <>
            "The label carries no structure: pass :project_slug (what the label was built from)."
        )

        {:error, :project_required}
    end
  end

  defp brief_guard(%CapProfile{} = cap_profile, opts) do
    cond do
      order_present?(opts) ->
        :ok

      Keyword.get(opts, :allow_no_brief, false) ->
        :ok

      brief_required?(cap_profile) ->
        Logger.warning(
          "Spawner: spawn_pod refused: one-shot pod without order — " <>
            "provide :brief (the text), :brief_ref (the address of a materialized brief), " <>
            "or :allow_no_brief (admin/diagnostic)."
        )

        {:error, :brief_required}

      true ->
        :ok
    end
  end

  @doc """
  Kills registered pods whose IDs carry the repository's scope prefix.

  Returns the count and sorted IDs of successful kills. Permanent and architect
  IDs without that prefix are spared. Registry enumeration includes unresponsive
  pods that `list_pods/0` would omit.
  """
  @spec kill_project_pods(String.t()) ::
          {:ok, %{killed: non_neg_integer(), pod_ids: [String.t()]}}
  def kill_project_pods(repo) when is_binary(repo) do
    prefix = Fleet.PodId.scope_prefix(repo)

    killed =
      Fleet.Spawner.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.filter(&(String.starts_with?(&1, prefix) and kill_pod(&1) == :ok))
      |> Enum.sort()

    if killed != [] do
      Logger.info(
        "Spawner: killed #{length(killed)} worker pod(s) of #{repo} — #{Enum.join(killed, ", ")}"
      )
    end

    {:ok, %{killed: length(killed), pod_ids: killed}}
  end

  @doc """
  Terminates a pod by its ID. Returns `:ok` if found, `{:error, :not_found}` otherwise.
  """
  @spec kill_pod(String.t()) :: :ok | {:error, :not_found}
  def kill_pod(pod_id) when is_binary(pod_id) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        try do
          :ok = GenServer.call(pid, :kill, 5_000)
          :ok
        catch
          :exit, _reason ->
            _ = DynamicSupervisor.terminate_child(Fleet.Spawner.Supervisor, pid)

            # A mute pod cannot release its mandate; do it after forced termination.
            _ = safe_clear_for_pod(pod_id)
            :ok
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp safe_clear_for_pod(pod_id) do
    Fleet.TaskQueue.clear_for_pod(pod_id)
    :ok
  rescue
    e ->
      Logger.error(
        "Spawner: kill_pod could NOT release the mandate of #{pod_id} (#{inspect(e)}) — the work item may " <>
          "stay active → poller reclaim → kill/re-dispatch loop"
      )

      :ok
  catch
    :exit, reason ->
      Logger.error(
        "Spawner: kill_pod could NOT release the mandate of #{pod_id} (TaskQueue exit: #{inspect(reason)}) " <>
          "— the work item may stay active → poller reclaim → kill/re-dispatch loop"
      )

      :ok
  end

  @doc """
  Resets a resident pipe workspace for its next project and requests REPL `/clear`.

  The caller must establish that the pod is ready and not publishing.
  A failed `/clear` is logged but the successful disk reset still returns `:ok`.
  Lookup, call and disk-reset failures return `{:error, reason}`.
  """
  @spec reprovision_pipe_workspace(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def reprovision_pipe_workspace(pod_id, project, opts \\ [])
      when is_binary(pod_id) and is_map(project) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
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
  Refreshes `refs/lcars/base` in a live pod's workspace without resetting its
  working tree or REPL context. Returns `{:error, :not_found}` for an absent pod.
  """
  @spec refresh_work_base(String.t(), map()) :: :ok | {:error, term()}
  def refresh_work_base(pod_id, project) when is_binary(pod_id) and is_map(project) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:refresh_work_base, project}, 30_000)
        catch
          :exit, reason -> {:error, {:refresh_call_failed, reason}}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Returns the deliverable workspace for an already-known pod directory."
  @spec pod_workspace_path(Path.t()) :: Path.t()
  def pod_workspace_path(pod_dir) when is_binary(pod_dir),
    do: Fleet.Spawner.Pod.Paths.pod_workspace_path(pod_dir)

  @doc """
  Returns a live pod's info, `:not_found` for proven absence, or `:unreachable` when
  the call fails without proving death. Destructive consumers must defer on `:unreachable`.
  """
  @spec pod_info(String.t(), timeout()) :: {:ok, map()} | {:error, :not_found | :unreachable}
  def pod_info(pod_id, timeout \\ 5_000) when is_binary(pod_id) do
    case Registry.lookup(Fleet.Spawner.Registry, pod_id) do
      [{pid, _}] ->
        try do
          {:ok, GenServer.call(pid, :info, timeout)}
        catch
          :exit, {:noproc, _} -> {:error, :not_found}
          :exit, {:normal, _} -> {:error, :not_found}
          :exit, {:shutdown, _} -> {:error, :not_found}
          :exit, {{:shutdown, _}, _} -> {:error, :not_found}
          :exit, _other -> {:error, :unreachable}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Checks for a regular `state.json` under any scope directory for this pod ID.

  This checks file existence, not snapshot contents or pod liveness.
  An unreadable state root returns `false`.
  """
  @spec snapshot_on_record?(String.t(), keyword()) :: boolean()
  def snapshot_on_record?(pod_id, opts \\ []) when is_binary(pod_id) and is_list(opts) do
    root = Fleet.Spawner.Pod.Paths.state_fs_root_for(opts)

    case File.ls(root) do
      {:ok, scopes} ->
        Enum.any?(scopes, &File.regular?(Path.join([root, &1, pod_id, "state.json"])))

      {:error, _} ->
        false
    end
  end

  @doc """
  Enumerates reachable live pods for observability without exposing the Registry.

  Absent and unreachable entries are both omitted; destructive decisions use `pod_info/2`.
  """
  @spec list_pods() :: [map()]
  def list_pods do
    Fleet.Spawner.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn pod_id ->
      case pod_info(pod_id) do
        {:ok, info} -> [info]
        {:error, _} -> []
      end
    end)
  end

  @doc """
  Reads fleet debug visibility from `:lcars_fleet, :spawner_debug_visibility`
  (default `false`), shared by pod launch and deliverable provenance.
  """
  @spec debug_visibility?() :: boolean()
  def debug_visibility? do
    Application.get_env(:lcars_fleet, :spawner_debug_visibility, false) == true
  end

  @doc """
  Reads `:lcars_fleet, :spawner_output_compression` (default `true`).

  `false` disables compression fleet-wide; `true` allows each profile to decide.
  """
  @spec output_compression_allowed?() :: boolean()
  def output_compression_allowed? do
    Application.get_env(:lcars_fleet, :spawner_output_compression, true) == true
  end

  @doc """
  Number of active pods.
  """
  @spec count_pods() :: non_neg_integer()
  def count_pods do
    %{active: active} = DynamicSupervisor.count_children(Fleet.Spawner.Supervisor)
    active
  end

  @doc """
  Fleet-wide pod limit, configured by `:lcars_fleet, :spawner_max_pods` (default 128).

  Enforced as the supervisor's `max_children`; excess starts return
  `{:error, :max_children}`. This resource ceiling is separate from per-role pools
  and per-project workflow concurrency.
  Size it for the combined peak of concurrent projects plus permanent pods;
  the default is chosen headroom, not a limit derived from project configuration.
  """
  @spec max_pods() :: pos_integer()
  def max_pods, do: Application.get_env(:lcars_fleet, :spawner_max_pods, 128)

  @doc """
  Checks pool availability for a role, repository ID and slot scope.

  This is advisory: capacity can change before spawn. Allocation is enforced
  by `PoolSlot.allocate/3` during the supervisor's serialized start.
  """
  @spec has_free_slot?(String.t(), integer() | nil, String.t()) :: boolean()
  defdelegate has_free_slot?(role, repo, slot_scope), to: Fleet.Spawner.PoolSlot

  @doc """
  Requests a new work cycle through `turn.flag` and arms the fallback kick and
  response deadline. Enqueue the pod's work in `Fleet.TaskQueue` before calling.

  `:ok` does not acknowledge delivery: flag-write failures are logged and casts
  are asynchronous. The pod observes delivery and response separately.
  Returns `{:error, :not_found | :unreachable | :not_a_tmux_pod}` when the pod is
  absent or unreachable, or has no tmux session.
  """
  @spec wake_pod(String.t()) :: :ok | {:error, :not_found | :not_a_tmux_pod | :unreachable}
  def wake_pod(pod_id) when is_binary(pod_id) do
    case pod_info(pod_id) do
      {:ok, %{tmux_session: session} = info} when is_binary(session) ->
        _ = Fleet.Spawner.Pod.TurnFlag.touch(info)
        _ = GenServer.cast(Pod.name(pod_id), :rearm_deadline)
        _ = GenServer.cast(Pod.name(pod_id), :arm_kick)
        :ok

      {:ok, _info} ->
        {:error, :not_a_tmux_pod}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Sends a best-effort informational message through `turn.flag`, without arming
  the work-cycle fallback or response deadline.

  Lookup failures return `{:error, reason}` and are logged. Flag-write failures
  are logged by `TurnFlag` but return `:ok`; delivery is not acknowledged.
  """
  @spec notify_pod(String.t(), String.t()) :: :ok | {:error, term()}
  def notify_pod(pod_id, message) when is_binary(pod_id) and is_binary(message) do
    case pod_info(pod_id) do
      {:ok, info} ->
        Fleet.Spawner.Pod.TurnFlag.touch(info, message)

      {:error, reason} ->
        Logger.warning(
          "Spawner: notify_pod #{pod_id} NOT delivered (#{inspect(reason)}) — the pod is not in " <>
            "the registry (never started, restarting, or killed); the message is LOST, nothing " <>
            "replays it"
        )

        {:error, reason}
    end
  end

  @doc """
  Returns `:temporary` for every lifetime scope; dead pods are not restarted
  by the supervisor.
  """
  @spec restart_strategy_for(String.t() | nil) :: :temporary
  def restart_strategy_for(_scope), do: :temporary

  @doc "Runs the same canonical-role spawn-readiness proof used at boot."
  @spec prove_canon!() :: :ok
  defdelegate prove_canon!(), to: Fleet.Spawner.CanonProof, as: :prove_all!

  defp pod_child_spec(args) do
    cap_profile = args.cap_profile
    scope = CapProfile.lifetime_scope(cap_profile)

    %{
      id: args.pod_id,
      start: {Pod, :start_link, [args]},
      restart: restart_strategy_for(scope),
      # Bounds shutdown cleanup; pod lifetime is controlled separately.
      shutdown: 15_000,
      type: :worker
    }
  end

  defp generate_pod_id, do: UUID.uuid4()
end
