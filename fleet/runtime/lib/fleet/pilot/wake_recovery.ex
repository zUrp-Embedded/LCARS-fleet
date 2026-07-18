defmodule Fleet.Pilot.WakeRecovery do
  @moduledoc """
  Hardening of `Fleet.Spawner.wake_pod/1`. A wake failure (pod unreachable: `:not_found`,
  tmux absent/dead) is NOT blocking in itself. The model:

    - **already seen** — the incident is in the persistent registry `Fleet.Pilot.IncidentRegistry` (so already
      occurred, possibly in a previous session) → **DIRECT escalation**: pattern, not random → root-cause;
    - **first time** → **re-roll** (injected re-spawn + re-wake):
        - re-wake OK → **recovered** → we RECORD the incident in the registry (anchor for next time);
        - re-wake FAIL → the re-roll did not repair → **IMMEDIATE escalation** (active problem).

  Escalation = system issue (`fleet/lcars`, label `error_system`, assignee `starfleet`=sysadmin), `reason`
  preserved, 2 distinct gates (`:recurrence` / `:reroll_failed`). Boundary: a failed wake = **a FLEET
  problem → starfleet** (which can re-spawn/repair), NOT the gatekeeper (project judge). **The memory
  lives in the PROJECT** (registry `work/ops`), not the session: session executes, project remembers,
  system repairs.

  Seams (functions) for testing; defaults = the real fns. `wake/3` API unchanged for the callers.

  **Last revised**: 2026-07-18
  """
  require Logger

  alias Fleet.Pilot.IncidentRegistry

  @doc """
  Wakes `pod_id` with recovery. `respawn_fun/0` = the type-specific re-spawn injected by the caller
  (gatekeeper reboot; worker re-spawn). Prerequisite: the brief is ALREADY queued.

  Returns `:ok` | `{:error, term()}` (from the re-wake) | `{:error, {:escalated, reason}}` (sysadmin issue
  ACTUALLY opened) | `{:error, {:escalation_failed, reason}}` (recurrence/re-roll failed but the issue
  opening failed — forge down? — NO issue exists: HONEST return, not a reassuring `:escalated`).
  """
  @spec wake(String.t(), (-> any()), keyword()) :: :ok | {:error, term()}
  def wake(pod_id, respawn_fun, opts \\ [])
      when is_binary(pod_id) and is_function(respawn_fun, 0) do
    wake_fun = Keyword.get(opts, :wake_fun, &Fleet.Spawner.wake_pod/1)

    case wake_fun.(pod_id) do
      :ok -> :ok
      {:error, reason} -> handle_fail(pod_id, reason, respawn_fun, wake_fun, opts)
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
        # The incident anchor MUST persist: it is what makes the NEXT occurrence of `sig` a RECURRENCE
        # (→ direct escalation). A swallowed note-failure + a log claiming "recorded" would be a lie —
        # the recurrence would be seen as a first-time wake and re-rolled forever, no escalation.
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

  # Opens the sysadmin issue AND propagates the OBSERVED result (never `:escalated` out of optimism):
  #   - issue opened (`{:ok, _}`) → `{:error, {:escalated, reason}}` (wake failed + alarm raised);
  #   - opening failed (`{:error, _}`, forge down?) → LOUD log + `{:error, {:escalation_failed, _}}`:
  #     NO issue exists, the caller must not believe a sysadmin was notified.
  # Shared by the 2 escalation gates (direct recurrence / exhausted re-roll) — same propagation.
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
