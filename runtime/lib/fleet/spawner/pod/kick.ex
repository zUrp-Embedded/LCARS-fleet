defmodule Fleet.Spawner.Pod.Kick do
  @moduledoc """
  Timing, acknowledgement decisions and tmux input for the pod's bounded kick loop.
  `engage` bootstraps the agent; `wake` is a fallback for an undelivered brief. The brief itself
  stays in TaskQueue and is pulled through MCP, never injected as terminal input.

  `Pod` owns timers, task probes, Monitor delivery/arming checks and the readiness gate.
  It waits for both MCP connection and live tmux before sending, because tmux buffers input
  during cold start. Waiting still consumes attempts. A pod without tmux skips the loop.
  Settings below are read from `:lcars_fleet` when called.
  """

  require Logger

  alias Fleet.Spawner.PodTmux

  @doc "First launch probe delay in ms: `:spawner_kick_first_delay_ms`, default 2000."
  @spec kick_first_delay_ms() :: non_neg_integer()
  def kick_first_delay_ms,
    do: Application.get_env(:lcars_fleet, :spawner_kick_first_delay_ms, 2_000)

  @doc """
  First wake fallback delay in ms: `:spawner_wake_first_delay_ms`, default 15000.
  Allow time for flag polling (1s), Monitor batching, turn start and get_work_item delivery;
  an early fallback can type a duplicate wake during normal delivery.
  """
  @spec wake_first_delay_ms() :: non_neg_integer()
  def wake_first_delay_ms,
    do: Application.get_env(:lcars_fleet, :spawner_wake_first_delay_ms, 15_000)

  @doc """
  Retry delay in ms for a pending brief before the first poll: `:spawner_kick_retry_ms`,
  default 2500. Readiness is enforced by the handler, not by choosing a longer delay.
  """
  @spec kick_retry_ms() :: non_neg_integer()
  def kick_retry_ms, do: Application.get_env(:lcars_fleet, :spawner_kick_retry_ms, 2_500)

  @doc "Wake retry delay after the first poll: `:spawner_wake_retry_ms`, default 10000 ms, allowing Monitor delivery time."
  @spec wake_retry_ms() :: non_neg_integer()
  def wake_retry_ms, do: Application.get_env(:lcars_fleet, :spawner_wake_retry_ms, 10_000)

  @doc "Pending-brief attempt cap: `:spawner_kick_max_attempts`, default 12; exhaustion emits `wake.failed`."
  @spec kick_max_attempts() :: non_neg_integer()
  def kick_max_attempts, do: Application.get_env(:lcars_fleet, :spawner_kick_max_attempts, 12)

  @doc """
  No-brief bootstrap attempt cap: `:spawner_kick_bootstrap_max`, default 30.
  The default 8s cadence allows about four minutes for cold caches and contention at startup.
  Activity can re-arm the separate response deadline; it does not reset this attempt counter.
  """
  @spec kick_bootstrap_max() :: non_neg_integer()
  def kick_bootstrap_max, do: Application.get_env(:lcars_fleet, :spawner_kick_bootstrap_max, 30)

  @doc "No-brief bootstrap retry delay: `:spawner_kick_bootstrap_retry_ms`, default 8000 ms."
  @spec kick_bootstrap_retry_ms() :: non_neg_integer()
  def kick_bootstrap_retry_ms,
    do: Application.get_env(:lcars_fleet, :spawner_kick_bootstrap_retry_ms, 8_000)

  @doc false
  # A pulled brief acknowledges work delivery; a poll alone suffices for no-brief bootstrap.
  @spec acked?(boolean(), boolean(), boolean()) :: boolean()
  def acked?(pulled?, bootstrap?, polled), do: pulled? or (bootstrap? and polled)

  @doc """
  Sends `engage` before the first get_work_item poll, otherwise `wake`.
  Global `:spawner_wake_send_keys` gates only wake fallback, allowing Monitor-only validation
  without disabling worker bootstrap. Profile `invocation.wake_send_keys: false` gates both
  keywords: human terminals are armed by the human/bridge, and injected input creates stray turns.
  The different keywords distinguish startup from fallback in logs. Send failures are logged.
  """
  @spec kick_send(map(), boolean()) :: :ok
  def kick_send(state, polled) do
    fallback_on? = Application.get_env(:lcars_fleet, :spawner_wake_send_keys, true)

    case kick_keyword(polled, fallback_on?, profile_send_keys?(state)) do
      nil -> :ok
      key -> do_send_keys(state, key)
    end
  end

  @doc """
  Returns whether the cap profile permits any kick send-keys, including `engage`.
  """
  @spec profile_send_keys?(map()) :: boolean()
  def profile_send_keys?(state),
    do: Fleet.CapProfile.wake_send_keys?(Map.get(state, :cap_profile))

  @doc false
  # Resume alone must not suppress engage: launch resets .seen, so the new Monitor needs arming.
  # Otherwise a resumed worker can hold capacity indefinitely with a pending flag and no Monitor.
  # Broker poll history also disappears on fleet restart; human terminals are protected by profile,
  # not by resume status. Pod cancels bootstrap once the new Monitor is armed.
  @spec kick_keyword(boolean(), boolean(), boolean()) :: String.t() | nil
  def kick_keyword(polled, fallback_on?, profile_allows?) do
    cond do
      not profile_allows? -> nil
      not polled -> "engage"
      fallback_on? -> "wake"
      true -> nil
    end
  end

  defp do_send_keys(state, key) do
    case PodTmux.send_keys(state.pod_id, key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("pod #{state.pod_id} kick (#{key}) failed: #{inspect(reason)}")
    end
  end
end
