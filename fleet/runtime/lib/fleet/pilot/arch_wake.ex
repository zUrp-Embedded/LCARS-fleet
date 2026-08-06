defmodule Fleet.Pilot.ArchWake do
  @moduledoc """
  SINGLE authority for waking a project's architect on an `lcars-awaits-arch`
  escalation: the ORDERED offer-then-wake pair, shared by the two rails — PER-PROJECT
  since the 2026-07-19 reorg (one architect per repo, `Fleet.Pilot.ProjectArchitect`).

  Callers (design 2026-07-19 — "first kick immediate, protection BEHIND it"):

    * `StepRunConsumer.TerminalEscalation.freeze_to_arch` — the IMMEDIATE rail
      (`via: "immediate"`): fires right after the label+comment land on the forge.
      Nominal escalation latency = seconds, not a poll window.
    * `Poller.maybe_rekick_arch` — the SAFETY NET (`via: "net"`): re-derives a wake
      from the persistent forge label, capped by a cooldown-since-last-kick.

  ## Per-project grouping + on-demand ensure (reorg 2026-07-19)

  `awaits` may span repos → grouped BY REPO, each repo's architect addressed independently
  (project A no longer serializes behind project B — the "one mandate at a time" queue is
  now per-project). Before waking, the architect is **ensured** (`ProjectArchitect.ensure`,
  idempotent): the arch is spawn-on-demand like the engineer — dead/never-spawned (fleet
  reboot, crash) → respawned here, and its bootstrap kick pulls the already-enqueued
  mandate. The ORDER stays the invariant: mandate enqueued BEFORE any wake (a wake fired
  before the mandate exists is classified spurious by the arch's doctrine-first
  `get_work_item` — signal-before-content race, live 2026-07-18).

  Contract — per-repo outcomes, decided on that arch's LATEST work-item state:

    * mandate `:assigned` → `:busy`, complete silence — the arch already
      knows its work; waking it again is pure noise (live 2026-07-18).
    * mandate `:pending` (offered but never fetched) → ensure + wake ONLY (`:woken_pending`).
      The signal may have been lost OR the pod died with the mandate pending — the ensure
      covers both; the content is already enqueued, re-offering would churn it.
    * arch free → enqueue the mandate (smallest `{repo, n}` of the repo — deterministic),
      THEN ensure, THEN wake (`:offered`).

  In the `:pending` and free cases, if the wake itself does not leave (unreachable arch)
  the outcome is `:wake_unreached`: the mandate/label persist, NO cooldown is armed, and the
  next tick retries — a cooldown on a signal that never left would make the escalation wait
  for nothing.

  A failed enqueue → `{:error, {:enqueue, reason}}`, logged loud, NO wake (a wake without
  content is the race above). A failed ensure is logged and the wake still attempted
  (belt: the pod may exist outside the registry's view). Nothing is lost either way: the
  `lcars-awaits-arch` label persists on the forge and the net retries.

  The aggregate return (multi-repo): `:offered` if ANY repo was offered, else `:woken_pending`
  if any, else the first outcome — so the poller stamps its cooldown ONLY on a signal that
  actually left (`:offered`/`:woken_pending`), never on `:busy` / `:wake_unreached` / an
  enqueue error.

  **Last revised**: 2026-08-03
  """

  require Logger

  alias Fleet.Pilot.ProjectArchitect

  @type outcome ::
          :offered | :woken_pending | :busy | :wake_unreached | {:error, {:enqueue, term()}}

  @doc """
  Offers and wakes the architect for each repository represented in `awaits`.
  """
  @spec offer_then_wake(
          module(),
          module(),
          {String.t(), pos_integer()} | MapSet.t(),
          String.t(),
          keyword()
        ) :: outcome()
  def offer_then_wake(task_queue, spawner, awaits, via, opts \\ []) do
    ensure = Keyword.get(opts, :ensure, &ProjectArchitect.ensure/2)

    awaits
    |> normalize()
    |> Enum.group_by(fn {repo, _n} -> repo end)
    |> Enum.map(fn {repo, pairs} ->
      offer_one(task_queue, spawner, repo, Enum.min(pairs), via, ensure)
    end)
    |> aggregate()
  end

  defp normalize({repo, n}) when is_binary(repo), do: [{repo, n}]
  defp normalize(%MapSet{} = awaits), do: MapSet.to_list(awaits)

  defp offer_one(task_queue, spawner, repo, {repo, n}, via, ensure) do
    pod_id = ProjectArchitect.pod_id_for(repo)

    case task_queue.pod_status(pod_id) do
      {:ok, :assigned} ->
        :busy

      {:ok, :pending} ->
        ensure_arch(ensure, repo, spawner, via)

        case wake(spawner, pod_id, via, "pending mandate never fetched → re-wake only") do
          :ok -> :woken_pending
          {:error, _} -> :wake_unreached
        end

      _free_or_terminal_or_never ->
        case enqueue_mandate(task_queue, pod_id, repo, n) do
          :ok ->
            ensure_arch(ensure, repo, spawner, via)

            case wake(spawner, pod_id, via, "mandate #{repo}##{n} enqueued (arch was free)") do
              :ok -> :offered
              {:error, _} -> :wake_unreached
            end

          {:error, reason} ->
            Logger.warning(
              "ArchWake: [#{via}] mandate enqueue KO (#{repo}##{n}): #{inspect(reason)} — " <>
                "NO wake sent (signal without content is the spurious-wake race); label intact, net retries"
            )

            {:error, {:enqueue, reason}}
        end
    end
  end

  # Aggregate multi-repo outcomes onto the historical single-atom contract (the poller's net
  # stamps its cooldown on any SENT signal).
  defp aggregate([outcome]), do: outcome

  defp aggregate(outcomes) do
    cond do
      :offered in outcomes -> :offered
      :woken_pending in outcomes -> :woken_pending
      true -> List.first(outcomes)
    end
  end

  # On-demand ensure — best-effort: a dead/never-spawned arch comes back here (fleet reboot,
  # crash); alive → cheap no-op. A failed ensure is LOGGED, the wake still attempted (belt).
  defp ensure_arch(ensure, repo, spawner, via) do
    case ensure.(repo, spawner: spawner) do
      {:ok, _pod_id} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ArchWake: [#{via}] arch ensure for #{repo} KO (#{inspect(reason)}) — wake still attempted; " <>
            "label intact, net retries"
        )

        :ok
    end
  end

  defp enqueue_mandate(task_queue, pod_id, repo, n) do
    attrs = %{
      issue_id: "issue-#{n}",
      # Same source as the ensure (`ProjectArchitect`): the delegate is resolved by capability, so a
      # mandate is never enqueued for a role the catalogue no longer carries.
      role: Fleet.Pilot.Roles.project_delegate_role(),
      brief:
        "Arbitrage requis : escalade sur l'issue `##{n}` de ton projet. Lis-la (`list_escalations` / " <>
          "`get_issue_status`), tranche avec ton humain, puis réponds (`comment_issue`) ou " <>
          "corrige+re-délègue (`create_issue` avec `supersedes: #{n}` — la fleet retire l'ancien " <>
          "ticket elle-même ; sans ça il repart en dispatch après ton submit_result). " <>
          "Ferme le work-item (`submit_result`) quand c'est traité — la fleet retire alors le label d'attente.",
      metadata: %{"awaits_arch" => true, "repo" => repo, "number" => n}
    }

    case task_queue.enqueue(pod_id, attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Returns the EFFECTIVE verdict: `:ok` only if the signal actually left. A caller that stamps a
  # cooldown on "signal sent" must not be told `:ok` for a wake that never reached — that is what
  # made an unreached escalation wait a full cooldown before the next attempt.
  defp wake(spawner, pod_id, via, context) do
    case spawner.wake_pod(pod_id) do
      :ok ->
        Logger.info("ArchWake: [#{via}] #{context} → wake sent to #{pod_id}")
        :ok

      other ->
        Logger.warning(
          "ArchWake: [#{via}] #{context} — wake #{pod_id} UNREACHED (#{inspect(other)}); " <>
            "forge label intact, net retries, the ensure respawns the arch on the next trigger"
        )

        {:error, other}
    end
  end
end
