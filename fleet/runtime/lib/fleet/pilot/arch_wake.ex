defmodule Fleet.Pilot.ArchWake do
  @moduledoc """
  SINGLE authority for waking the permanent architect on an `lcars-awaits-arch`
  escalation: the ORDERED offer-then-wake pair, shared by the two rails.

  Callers (design 2026-07-19 — "first kick immediate, protection BEHIND it"):

    * `StepRunConsumer.TerminalEscalation.freeze_to_arch` — the IMMEDIATE rail
      (`via: "immediate"`): fires right after the label+comment land on the forge.
      Nominal escalation latency = seconds, not a poll window.
    * `Poller.maybe_rekick_arch` — the SAFETY NET (`via: "net"`): re-derives a wake
      from the persistent forge label, capped by a cooldown-since-last-kick.

  Contract — 3 outcomes, decided on the arch's LATEST work-item state:

    * arch FREE → enqueue the arbitration mandate THEN wake (`:offered`). The ORDER is
      the invariant: a wake fired before the mandate exists is classified spurious by the
      arch's doctrine-first `get_work_item` (`{done:true}` — signal-before-content race,
      live 2026-07-18). Killing the race by ORDERING beats killing it by WAITING (the
      grid-throttle detour turned "5 min max" into 0-5 min nominal, scar 2026-07-19).
    * mandate `:pending` (offered but never fetched) → wake ONLY (`:woken_pending`).
      The signal may have been lost; the content is already enqueued — re-offering would
      churn it. This also closes the lost-wake liveness hole (a pending mandate no longer
      silences the net forever).
    * mandate `:assigned`/`:in_progress` → `:busy`, complete silence — the arch already
      knows its work; waking it again is pure noise (live 2026-07-18).

  A failed enqueue → `{:error, {:enqueue, reason}}`, logged loud, NO wake (a wake without
  content is the race above). Nothing is lost either way: the `lcars-awaits-arch` label
  persists on the forge and the net retries. The mandate targets the SMALLEST `{repo, n}`
  (deterministic across ticks/callers; the arch drains one at a time WITH the human).

  **Last revised**: 2026-07-19
  """

  require Logger

  alias Fleet.Pilot.Roles

  @type outcome :: :offered | :woken_pending | :busy | {:error, {:enqueue, term()}}

  @doc """
  Offer-then-wake the arch for `awaits` (a `{repo, n}` tuple or a non-empty MapSet of
  them). `via` tags the calling rail in the logs (`"immediate"` / `"net"`).
  """
  @spec offer_then_wake(module(), module(), {String.t(), pos_integer()} | MapSet.t(), String.t()) ::
          outcome()
  def offer_then_wake(task_queue, spawner, awaits, via) do
    pod_id = Roles.architect_pod_id()

    case task_queue.pod_status(pod_id) do
      {:ok, state} when state in [:assigned, :in_progress] ->
        :busy

      {:ok, :pending} ->
        wake(spawner, pod_id, via, "pending mandate never fetched → re-wake only")
        :woken_pending

      _free_or_terminal_or_never ->
        {repo, n} = pick(awaits)

        case enqueue_mandate(task_queue, pod_id, repo, n) do
          :ok ->
            wake(spawner, pod_id, via, "mandate #{repo}##{n} enqueued (arch was free)")
            :offered

          {:error, reason} ->
            Logger.warning(
              "ArchWake: [#{via}] mandate enqueue KO (#{repo}##{n}): #{inspect(reason)} — " <>
                "NO wake sent (signal without content is the spurious-wake race); label intact, net retries"
            )

            {:error, {:enqueue, reason}}
        end
    end
  end

  defp pick({repo, n}) when is_binary(repo), do: {repo, n}
  defp pick(%MapSet{} = awaits), do: Enum.min(awaits)

  defp enqueue_mandate(task_queue, pod_id, repo, n) do
    attrs = %{
      issue_id: "issue-#{n}",
      role: "architect",
      brief:
        "Arbitrage requis : escalade sur l'issue `#{repo}##{n}`. Lis-la (`list_escalations` / " <>
          "`get_issue_status`), tranche avec ton humain, puis réponds (`comment_issue`) ou corrige+re-délègue. " <>
          "Ferme le work-item (`submit_result`) quand c'est traité — la fleet retire alors le label d'attente.",
      metadata: %{"awaits_arch" => true, "repo" => repo, "number" => n}
    }

    case task_queue.enqueue(pod_id, attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp wake(spawner, pod_id, via, context) do
    case spawner.wake_pod(pod_id) do
      :ok ->
        Logger.info("ArchWake: [#{via}] #{context} → wake sent to #{pod_id}")

      other ->
        Logger.warning(
          "ArchWake: [#{via}] #{context} — wake #{pod_id} UNREACHED (#{inspect(other)}); " <>
            "forge label intact, net retries, PermanentWarden respawns the arch"
        )
    end
  end
end
