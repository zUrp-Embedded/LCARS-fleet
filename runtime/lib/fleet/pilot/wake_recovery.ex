defmodule Fleet.Pilot.WakeRecovery do
  @moduledoc """
  Recovers failed wakes: known signatures escalate directly; first failures invoke
  respawn once, then retry wake. A successful retry attempts to record the incident.
  An initial :unreachable is not proof of death and returns without respawning.

  Escalation bypasses registry cooldown and relies on Escalation's open-issue
  readback. Callback exceptions propagate; recovery does not schedule a future retry.
  """
  require Logger

  alias Fleet.Pilot.IncidentRegistry

  @doc """
  Wakes a pod whose brief is already queued. The caller supplies respawn_fun/0;
  its return is ignored before re-waking the same pod ID.

  :ok means wake succeeded, even if recording the recovered incident failed (logged).
  Escalation success returns {:error, {:escalated, original_reason}}. Escalation
  failure returns {:error, {:escalation_failed, cause}}; a created issue can still
  exist when adding its discovery label failed. Initial :unreachable is returned
  directly; any unsuccessful second wake attempts escalation.
  """
  @spec wake(String.t(), (-> any()), keyword()) :: :ok | {:error, term()}
  def wake(pod_id, respawn_fun, opts \\ [])
      when is_binary(pod_id) and is_function(respawn_fun, 0) do
    wake_fun = Keyword.get(opts, :wake_fun, &Fleet.Spawner.wake_pod/1)

    case wake_fun.(pod_id) do
      :ok ->
        :ok

      # A timed-out info call does not prove death; respawn could destroy a live agent.
      {:error, :unreachable} = err ->
        Logger.warning(
          "WakeRecovery: #{pod_id} UNREACHABLE (slow, not proven absent) → deferred, no re-roll"
        )

        err

      {:error, reason} ->
        handle_fail(pod_id, reason, respawn_fun, wake_fun, opts)
    end
  end

  defp handle_fail(pod_id, reason, respawn_fun, wake_fun, opts) do
    seen_before_fun = Keyword.get(opts, :seen_before_fun, &IncidentRegistry.seen_before?/1)
    note_fun = Keyword.get(opts, :note_fun, &IncidentRegistry.note/2)
    op = Keyword.get(opts, :op, "wake")
    sig = IncidentRegistry.signature(op, pod_id, reason)

    if seen_before_fun.(sig) do
      Logger.error(
        "WakeRecovery: #{pod_id} : #{inspect(reason)} ALREADY SEEN (#{sig}) → direct escalation (recurrence)"
      )

      escalate_or_signal(:recurrence, pod_id, reason, sig, opts)
    else
      Logger.warning("WakeRecovery: #{pod_id} : #{inspect(reason)} (1st — #{sig}) → re-roll")
      _ = respawn_fun.()
      re_wake(pod_id, reason, sig, wake_fun, note_fun, opts)
    end
  end

  defp re_wake(pod_id, reason, sig, wake_fun, note_fun, opts) do
    case wake_fun.(pod_id) do
      :ok ->
        # A failed note must not be logged as recorded. WAL failure can still leave
        # the registry's in-memory anchor intact, despite the broad log below.
        case note_fun.(sig, reason) do
          :ok ->
            Logger.info("WakeRecovery: #{pod_id} : re-roll OK → incident recorded (#{sig})")

          other ->
            Logger.error(
              "WakeRecovery: #{pod_id} : re-roll OK BUT incident anchor NOT recorded (#{inspect(other)}) " <>
                "— the next recurrence of #{sig} won't be detected as such (no escalation)"
            )
        end

        :ok

      err ->
        Logger.error(
          "WakeRecovery: #{pod_id} : re-roll did not repair (#{inspect(err)}) → immediate escalation"
        )

        escalate_or_signal(:reroll_failed, pod_id, reason, sig, opts)
    end
  end

  # Preserve escalation's result separately from wake failure. Label failure can
  # leave an existing issue despite this branch's unconditional log wording.
  defp escalate_or_signal(kind, pod_id, reason, sig, opts) do
    case IncidentRegistry.escalate(kind, pod_id, reason, sig, opts) do
      {:ok, _num} ->
        {:error, {:escalated, reason}}

      {:error, e} ->
        Logger.error(
          "WakeRecovery: #{pod_id} : escalation (#{kind}) FAILED — NO sysadmin issue created " <>
            "(forge down?): #{inspect(e)}; the incident is NOT escalated"
        )

        {:error, {:escalation_failed, e}}
    end
  end
end
