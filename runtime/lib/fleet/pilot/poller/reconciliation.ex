defmodule Fleet.Pilot.Poller.Reconciliation do
  @moduledoc """
  Reconciles two kinds of orphan from one pod snapshot and repo-qualified suspects:
  locked issues/PRs without pulled work, and instance pods with no observed lock
  or active task. Poller owns prior observations and calls this only for regular
  ticks; force_poll can advance observations without a minimum elapsed time.

  Lock ownership requires assigned work. Pending work protects a pod from reaping
  but does not protect its lock, allowing an unpulled admission to be retried.
  Completed work owns neither; observation grace reduces churn during publication
  without proving every late reclaim harmless. Issue and PR ownership stay separate:
  a producer must not indefinitely protect a dead judge's PR lock.

  Instance references come from PodId; project pods derive their issue from the
  active task, assigned gate evaluations add their resume issue, and an assigned task
  that holds a PR lock (review, rework: `lock_pr` in its metadata) owns that PR — the
  only way a producer owns a PR lock, and only while its rework task is assigned. Repo-qualified
  refs avoid number-only collisions but inherit PodId's lossy slug matching.

  A snapshot error or unknown ownership read preserves prior suspects and prevents
  this pass's destructive work. Exceptions/exits become unknown, but returned shapes
  are not uniformly conservative: pod_pull_state treats unexpected replies as not
  pulled; project-task lookup treats returned errors as no ref. Missing list_active
  or pod_active_issue_id capabilities also supply no refs. No atomic snapshot spans
  these separate broker and forge observations.

  Confirmed lock-removal errors remain suspect for next-pass retry. Reap outcomes
  are logged but not retained as confirmed suspects; survivors need fresh observation
  grace. The kill primitive belongs to StepDispatcher.Spawn.safe_kill/2.
  """

  alias Fleet.Forge.Payload
  alias Fleet.Grace

  require Logger

  @in_flight Fleet.Labels.in_flight()

  # Assigned work is the shared ownership criterion. Pending admission is active
  # for lifetime purposes but does not prove the executor pulled the mandate.
  @pulled_states [:assigned]

  # These files cite the ownership rule without calling it. The bidirectional
  # reconciliation.pulled_states_declared contract keeps the dependency list aligned.
  @pulled_states_dependents [
    "lib/fleet/pilot/step_run_consumer/gatekeeper_escalation.ex",
    "lib/fleet/pilot/step_dispatcher/spawn.ex",
    "lib/fleet/task_queue/server.ex"
  ]

  @doc """
  Lists source files that rely on @pulled_states without calling this module.
  The contract checker uses this declaration to keep those reasoning dependencies
  visible at their supplier; runtime reconciliation does not read the list.
  """
  @spec pulled_states_dependents() :: [String.t()]
  def pulled_states_dependents, do: @pulled_states_dependents

  defmodule Seams do
    @moduledoc """
    Dependency bundle rather than the poller's mutable state. The caller resolves
    production defaults. Enforced keys check construction presence, not runtime values.
    """
    @enforce_keys [:forge, :spawner, :task_queue, :repo, :forge_opts]
    defstruct [:forge, :spawner, :task_queue, :repo, :forge_opts]

    @type t :: %__MODULE__{
            # Injected forge client (seam `:forge_client`, prod default `Fleet.Forge.Client`).
            forge: module(),
            # Injected spawner, ALREADY resolved by the caller (seam `:spawner`, prod default `Fleet.Spawner`).
            spawner: module(),
            # Injected broker, ALREADY resolved by the caller (seam `:task_queue`, prod default `Fleet.TaskQueue`).
            task_queue: module(),
            # `owner/name` of the current repo (the lock refs are repo-qualified there).
            repo: String.t(),
            # Forge opts (base_url/token…) passed to the ForgeClient (`remove_label`).
            forge_opts: keyword()
          }
  end

  @doc """
  Acts on current orphans also present in this repo's prior_suspects. Reclaims
  issue/PR locks and reaps quiesced pods, returning new suspects plus failed lock
  reclaims. Ref shapes are {repo, :issue | :pr, number} and {repo, :pod, pod_id}.

  Pass the current repo's subset, not the cross-repo union. Snapshot errors or
  failed ownership reads retain that subset. Other exceptions during effects may
  propagate after partial work; no rollback is performed.
  """
  @spec reconcile(list(map()), list(map()), MapSet.t(), MapSet.t(), Seams.t(), [map()] | :error) ::
          MapSet.t()
  def reconcile(issues, pulls, pr_issue_ids, prior_suspects, %Seams{} = seams, pods) do
    # The caller takes one snapshot per tick, outside its repo loop. Passing the data
    # separately avoids repeated enumeration for ownership, reaping and diagnostics.
    case pods do
      {:error, _reason} ->
        prior_suspects

      pods when is_list(pods) ->
        reconcile_with_pods(issues, pulls, pr_issue_ids, prior_suspects, seams, pods)
    end
  end

  @doc """
  Calls list_pods once for the caller to reuse across repositories. Catches exceptions,
  throws and exits into {:error, reason}; returned values are not validated here.
  With Fleet.Spawner, individually unreachable pods may already be omitted from
  an otherwise successful listing.
  """
  @spec snapshot_pods(module()) :: [map()] | {:error, term()}
  def snapshot_pods(spawner) do
    spawner.list_pods()
  rescue
    e -> {:error, e}
  catch
    kind, why -> {:error, {kind, why}}
  end

  defp reconcile_with_pods(issues, pulls, pr_issue_ids, prior_suspects, %Seams{} = seams, pods) do
    case live_owned_refs(seams, pods) do
      # Unknown ownership preserves prior suspects without destructive action.
      :error ->
        prior_suspects

      owned ->
        repo = seams.repo

        # Never infer PR ownership from its producer's issue ownership: a delivered
        # producer would hide a dead judge. Completed tasks do not own locks;
        # retaining them would hide lost completion. Grace limits publication churn.

        issue_orphans =
          for i <- issues,
              n = i["number"],
              locked?(i),
              # an issue with an open PR is in JUDGE phase (lock on the PR side) → not an issue orphan
              not MapSet.member?(pr_issue_ids, n),
              not MapSet.member?(owned, {repo, :issue, n}),
              into: MapSet.new(),
              do: {repo, :issue, n}

        pr_orphans =
          for p <- pulls,
              n = p["number"],
              locked?(p),
              not MapSet.member?(owned, {repo, :pr, n}),
              into: MapSet.new(),
              do: {repo, :pr, n}

        # Tag inverse orphans as {repo, :pod, pod_id} in the same suspect set.
        zombie_pods = quiesced_brick_pods(issues, pulls, seams, pods)

        orphaned_now = issue_orphans |> MapSet.union(pr_orphans) |> MapSet.union(zombie_pods)
        {to_act, new_suspects} = Grace.two_tick(orphaned_now, prior_suspects)

        # Keep failed lock reclaims confirmed for next-pass retry. Reap failures instead
        # require re-suspicion and another confirming observation.
        failed_reclaims =
          to_act
          |> Enum.filter(fn
            {_repo, :pod, pod_id} ->
              # Deliberately discard the classified reap result after its log.
              _ = reap_pod(seams, pod_id)
              false

            {_repo, _type, n} ->
              reclaim_lock(seams, n, lock_diagnosis(seams, n, pods)) == :failed
          end)
          |> MapSet.new()

        MapSet.union(new_suspects, failed_reclaims)
    end
  end

  # Reap instance IDs only when their reference has no lock in these listings and
  # the broker reports idle. A missing item is also unlocked in this snapshot;
  # project IDs without an instance reference are outside this duty.
  defp quiesced_brick_pods(issues, pulls, %Seams{} = seams, pods) do
    locked_issues = for i <- issues, locked?(i), into: MapSet.new(), do: i["number"]
    locked_prs = for p <- pulls, locked?(p), into: MapSet.new(), do: p["number"]

    pods
    |> Enum.flat_map(&quiesced_pod(&1, seams, locked_issues, locked_prs))
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  catch
    _, _ -> MapSet.new()
  end

  # Reap on measured idle; active and unknown broker states defer.
  defp quiesced_pod(pod, %Seams{} = seams, locked_issues, locked_prs) do
    pod_id = pod[:pod_id]

    case parse_pod_ref(pod_id, seams.repo) do
      [{repo, phase, n}] ->
        locked? =
          (phase == :issue and MapSet.member?(locked_issues, n)) or
            (phase == :pr and MapSet.member?(locked_prs, n))

        if locked? or pod_task_state(seams.task_queue, pod_id) != :idle,
          do: [],
          else: [{repo, :pod, pod_id}]

      _ ->
        []
    end
  end

  # Log after safe_kill, distinguishing success, already absent and failure.
  # Caller policy re-observes failed reaps rather than retaining confirmation.
  defp reap_pod(%Seams{spawner: spawner, repo: repo}, pod_id) do
    outcome = Fleet.Pilot.StepDispatcher.Spawn.safe_kill(spawner, pod_id)

    case outcome do
      :ok ->
        Logger.info(
          "Poller: reconciliation : pod #{pod_id} QUIESCED on #{repo} " <>
            "(brick unlocked, no active task) → REAPED (a re-dispatch re-spawns fresh)"
        )

      {:error, :not_found} ->
        Logger.info(
          "Poller: reconciliation : pod #{pod_id} QUIESCED on #{repo} — already gone when the " <>
            "kill landed (nothing to do, the duty is satisfied)"
        )

      other ->
        Logger.warning(
          "Poller: reconciliation : pod #{pod_id} QUIESCED on #{repo} but the kill did NOT " <>
            "land (#{inspect(other)}) — NOT reaped; the next tick re-suspects and retries " <>
            "(self-healing, nothing is blocked)"
        )
    end

    outcome
  end

  # Combine pulled pod refs with assigned gate-evaluation resume refs. A gatekeeper
  # can own an issue whose producer is already idle; its task metadata supplies
  # the reference independently of the gatekeeper's pod ID.
  defp live_owned_refs(%Seams{task_queue: tq, repo: repo}, pods) do
    # One unknown broker read invalidates the ownership set. Propagate it explicitly;
    # treating :unknown as truthy or as empty would silently change destructive policy.
    pod_refs = Enum.reduce_while(pods, MapSet.new(), &pod_owned_step(&1, &2, tq, repo))

    case pod_refs do
      :error ->
        :error

      %MapSet{} ->
        pod_refs
        |> MapSet.union(gate_eval_owned_refs(tq, repo))
        |> MapSet.union(pr_lock_owned_refs(tq, repo))
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # Abort partial ownership accumulation when any read is unknown.
  defp pod_owned_step(pod, acc, tq, repo) do
    pod_id = pod[:pod_id]

    case pod_pull_state(tq, pod_id) do
      :unknown ->
        {:halt, :error}

      :not_pulled ->
        {:cont, acc}

      :pulled ->
        case owned_refs_for_pod(pod_id, repo, tq) do
          :unknown -> {:halt, :error}
          {:ok, refs} -> {:cont, MapSet.union(acc, MapSet.new(refs))}
        end
    end
  end

  # Assigned evaluations own their metadata's repo/issue; pending evaluations do not.
  # That can cause delayed evaluations to be reclaimed, rather than masking an
  # unpulled mandate indefinitely. Missing list_active capability supplies no refs.
  defp gate_eval_owned_refs(tq, repo) do
    if Fleet.Opts.exported?(tq, :list_active, 0) do
      for %{metadata: meta, state: item_state} <- tq.list_active(),
          item_state in @pulled_states,
          meta["gate_eval"] == true,
          Payload.repository_full_name(meta["resume_payload"]) == repo,
          n = meta["resume_n"],
          is_integer(n),
          into: MapSet.new(),
          do: {repo, :issue, n}
    else
      MapSet.new()
    end
  end

  # An ASSIGNED task that holds a PR lock owns it, whatever its pod is named: a producer reworking
  # its PR runs as `…-issue-<n>-<role>` while the lock sits on the PR. Only the assigned task counts —
  # a producer that already delivered holds nothing, so it cannot hide a dead judge.
  defp pr_lock_owned_refs(tq, repo) do
    if Fleet.Opts.exported?(tq, :list_active, 0) do
      for %{metadata: meta, state: item_state} <- tq.list_active(),
          item_state in @pulled_states,
          meta["repo"] == repo,
          n = meta["lock_pr"],
          is_integer(n),
          into: MapSet.new(),
          do: {repo, :pr, n}
    else
      MapSet.new()
    end
  end

  # Instance IDs carry their reference; project IDs need the active task's issue ID.
  defp owned_refs_for_pod(pod_id, repo, tq) do
    case parse_pod_ref(pod_id, repo) do
      [] -> project_pod_owned_refs(pod_id, repo, tq)
      refs -> {:ok, refs}
    end
  end

  # Prefix-scoped project ownership comes from the active issue ID. Missing capability,
  # returned errors and unparseable IDs yield no refs; exceptions/exits yield unknown.
  defp project_pod_owned_refs(pod_id, repo, tq) do
    with true <- String.starts_with?(pod_id, Fleet.PodId.scope_prefix(repo)),
         true <- Fleet.Opts.exported?(tq, :pod_active_issue_id, 1),
         {:ok, issue_id} when is_binary(issue_id) <- tq.pod_active_issue_id(pod_id),
         {:ok, n} <- Fleet.Pilot.IssueId.parse(issue_id) do
      {:ok, [{repo, :issue, n}]}
    else
      _ -> {:ok, []}
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  # For reaping, pending and assigned are active; terminal/nil states are idle.
  # Unexpected replies and exceptions/exits are unknown, so a broker outage does
  # not authorize killing a possibly working pod.
  @spec pod_task_state(module(), term()) :: :active | :idle | :unknown
  defp pod_task_state(tq, pod_id) when is_binary(pod_id) do
    case tq.pod_status(pod_id) do
      {:ok, state} -> if Fleet.TaskQueue.WorkItem.active?(state), do: :active, else: :idle
      # A seam that does not honour the `{:ok, _}` contract tells us nothing — not "idle".
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  # For lock ownership only assigned counts as pulled. Pending remains active for
  # reaping, but its lock can be reclaimed. Exceptions/exits yield unknown;
  # unexpected returned replies and non-binary IDs count as not pulled.
  defp pod_pull_state(tq, pod_id) when is_binary(pod_id) do
    case tq.pod_status(pod_id) do
      {:ok, state} -> if state in @pulled_states, do: :pulled, else: :not_pulled
      _ -> :not_pulled
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  defp pod_pull_state(_tq, _), do: :not_pulled

  # Dress PodId's parsed reference with repo scope; slug matching is not independent
  # proof of repository identity.
  defp parse_pod_ref(pod_id, repo) when is_binary(pod_id) and is_binary(repo) do
    case Fleet.PodId.parse_ref(pod_id, repo) do
      {:ok, {phase, n}} -> [{repo, phase, n}]
      :error -> []
    end
  end

  defp parse_pod_ref(_, _), do: []

  defp locked?(item) do
    @in_flight in Payload.label_names(item)
  end

  # Diagnostic only: matches instance IDs by number, without distinguishing issue/PR
  # phase or project-task ownership. The text is weaker evidence than its wording.
  defp lock_diagnosis(%Seams{repo: repo}, number, pods) do
    live_for_ref =
      pods
      |> Enum.filter(fn pod ->
        parse_pod_ref(pod[:pod_id], repo)
        |> Enum.any?(fn {_repo, _type, n} -> n == number end)
      end)

    case live_for_ref do
      [] -> "no live pod (dead/reaped)"
      _ -> "pod ALIVE but idle — no pulled task (parked wake, or completed without publish)"
    end
  rescue
    _ -> "pod state UNKNOWN (enumeration failed)"
  catch
    _, _ -> "pod state UNKNOWN (enumeration failed)"
  end

  defp reclaim_lock(%Seams{forge: forge, repo: repo, forge_opts: forge_opts}, number, diagnosis) do
    # Announce intent before the write, not a completed reclaim.
    Logger.warning(
      "Poller: reconciliation : lock #{@in_flight} ORPHAN on " <>
        "#{repo}##{number} (#{diagnosis}) → reclaiming (re-dispatch on next tick)"
    )

    # Attempt stopwatch stop with raw forge identity. It may not stop the role's
    # per-user timer. Returned failures are ignored; exceptions can prevent the
    # following label removal.
    _ = forge.stop_stopwatch(repo, number, forge_opts)

    # Returned removal errors retain confirmation for next-pass retry. Other return
    # shapes are accepted as success; exceptions propagate.
    case forge.remove_label(repo, number, @in_flight, forge_opts) do
      {:error, reason} ->
        Logger.error(
          "Poller: reconciliation : reclaim of #{repo}##{number} FAILED — #{@in_flight} NOT removed " <>
            "(#{inspect(reason)}) — lock persists, kept suspect, retry next tick"
        )

        :failed

      _ ->
        :ok
    end
  end
end
