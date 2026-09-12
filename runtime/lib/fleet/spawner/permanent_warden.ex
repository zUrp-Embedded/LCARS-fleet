defmodule Fleet.Spawner.PermanentWarden do
  @moduledoc """
  Schedules permanent-pod respawns through `PermanentBoot.respawn/2`.

  Handles `pod.failed` events and periodically compares expected roles with
  reachable pods from `Fleet.Spawner.list_pods/0`, covering missed failure events.
  Both paths share one pending timer and a retry counter per role.

  Immediate spawn failures retry up to five attempts with capped exponential
  backoff. An accepted launch records a timestamp without resetting the counter.
  Later death/reconciliation handling resets it if that timestamp is absent or
  at least `:min_uptime_ms` old. This is an elapsed-time heuristic, not a continuous
  liveness check; later reconciliation can therefore reopen an exhausted cycle.
  A drain refusal schedules no retry and leaves the already-scheduled count unchanged.

  Options:
    * `:subscribe` — subscribe to the Bus (default true).
    * `:respawn_fun` — `(role) -> {:ok, pod_id} | {:error, reason}`;
      defaults to `PermanentBoot.respawn/1`.
    * `:backoff_base_ms` — default 5_000; delay is capped at 600_000 ms.
    * `:min_uptime_ms` — default 60_000.
    * `:reconcile_ms` — default 60_000; `nil` disables the tick.
    * `:expected_roles_fun` / `:live_roles_fun` — zero-arity role-list providers.
    * `:reconcile_enabled_fun` — zero-arity predicate, defaulting to permanent boot
      enabled and fleet not quiescing. This gates reconciliation, not failure events.

  The domain supervisor starts this process when `:spawner_start_permanent_warden`
  is enabled (default true; disabled in test configuration).
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Spawner.PermanentBoot

  @max_attempts 5
  @max_delay_ms 600_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()
    respawn_fun = Keyword.get(opts, :respawn_fun, &PermanentBoot.respawn/1)
    base = Keyword.get(opts, :backoff_base_ms, 5_000)
    min_uptime = Keyword.get(opts, :min_uptime_ms, 60_000)
    reconcile_ms = Keyword.get(opts, :reconcile_ms, 60_000)

    state = %{
      respawn_fun: respawn_fun,
      base: base,
      min_uptime: min_uptime,
      reconcile_ms: reconcile_ms,
      expected_roles_fun: Keyword.get(opts, :expected_roles_fun, &default_expected_roles/0),
      live_roles_fun: Keyword.get(opts, :live_roles_fun, &default_live_roles/0),
      reconcile_enabled_fun:
        Keyword.get(opts, :reconcile_enabled_fun, &default_reconcile_enabled?/0),
      # role => {consecutive attempts, last successful warden launch monotonic time}
      attempts: %{},
      # One pending timer per role deduplicates bursts of failure events.
      pending: MapSet.new()
    }

    :ok = schedule_reconcile(reconcile_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(
        %Fleet.Event{source: :spawner, type: :"pod.failed", payload: %{"pod_id" => pod_id}},
        state
      )
      when is_binary(pod_id) do
    case PermanentBoot.parse_permanent(pod_id) do
      :not_permanent ->
        {:noreply, state}

      {:ok, role} ->
        handle_permanent_death(role, state)
    end
  end

  def handle_info({:respawn, role}, state) do
    state = %{state | pending: MapSet.delete(state.pending, role)}

    result =
      try do
        state.respawn_fun.(role)
      rescue
        e -> {:error, {:respawn_raised, Exception.message(e)}}
      end

    case result do
      {:ok, pod_id} ->
        Logger.info("PermanentWarden: permanent #{role} respawned (#{pod_id})")

        now = System.monotonic_time(:millisecond)

        attempts =
          Map.update(state.attempts, role, {0, now}, fn {count, _} -> {count, now} end)

        {:noreply, %{state | attempts: attempts}}

      {:error, {_role, :fleet_quiescing}} ->
        Logger.info(
          "PermanentWarden: respawn #{role} refused by the drain (fleet quiescing) — not an " <>
            "attempt, nothing to retry: the node is stopping"
        )

        {:noreply, state}

      {:error, reason} ->
        # Spawn failure emits no pod.failed, so re-arm the shared cycle here.
        {attempt, _stamp} = Map.get(state.attempts, role, {1, nil})

        if attempt < @max_attempts do
          delay = backoff_delay(attempt, state.base)

          Logger.warning(
            "PermanentWarden: respawn #{role} FAILED (#{inspect(reason)}) → retry in " <>
              "#{div(delay, 1000)}s (attempt #{attempt + 1}/#{@max_attempts})"
          )

          Process.send_after(self(), {:respawn, role}, delay)

          {:noreply,
           %{
             state
             | attempts: Map.put(state.attempts, role, {attempt + 1, nil}),
               pending: MapSet.put(state.pending, role)
           }}
        else
          Logger.error(
            "PermanentWarden: respawn #{role} — #{@max_attempts} consecutive failures, HALT " <>
              "(sysadmin issue already opened by the incident rail; intervention required)"
          )

          {:noreply, state}
        end
    end
  end

  def handle_info(:reconcile, state) do
    :ok = schedule_reconcile(state.reconcile_ms)

    if state.reconcile_enabled_fun.() do
      missing = expected_missing(state)

      for role <- missing do
        Logger.warning(
          "PermanentWarden: permanent #{role} MISSING at reconciliation (no pod.failed seen — " <>
            "sub-tree restart? lost event?) → respawn"
        )
      end

      {:noreply, Enum.reduce(missing, state, &schedule_respawn/2)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Unknown desired/live state schedules nothing.
  defp expected_missing(state) do
    expected = MapSet.new(state.expected_roles_fun.())
    live = MapSet.new(state.live_roles_fun.())

    expected |> MapSet.difference(live) |> MapSet.to_list()
  rescue
    e ->
      Logger.warning(
        "PermanentWarden: reconciliation enumeration failed (#{inspect(e)}) — nothing respawned this tick"
      )

      []
  catch
    _, _ -> []
  end

  defp schedule_respawn(role, state) do
    {:noreply, new_state} = handle_permanent_death(role, state)
    new_state
  end

  defp default_expected_roles, do: PermanentBoot.expected_permanent_roles()

  defp schedule_reconcile(ms) when is_integer(ms) do
    _ = Process.send_after(self(), :reconcile, ms)
    :ok
  end

  defp schedule_reconcile(_), do: :ok

  defp default_live_roles do
    Fleet.Spawner.list_pods()
    |> Enum.flat_map(fn pod ->
      case PermanentBoot.parse_permanent(pod[:pod_id] || "") do
        {:ok, role} -> [role]
        :not_permanent -> []
      end
    end)
  end

  defp default_reconcile_enabled? do
    PermanentBoot.auto_boot_enabled?() and not Fleet.Shutdown.Quiesce.quiescing?()
  end

  defp handle_permanent_death(role, state) do
    if MapSet.member?(state.pending, role) do
      Logger.debug("PermanentWarden: #{role} death while a respawn is already pending → deduped")
      {:noreply, state}
    else
      do_handle_permanent_death(role, state)
    end
  end

  defp do_handle_permanent_death(role, state) do
    now = System.monotonic_time(:millisecond)
    {raw_count, last_respawn} = Map.get(state.attempts, role, {0, nil})

    # Absent or old timestamps reset the budget on both events and reconciliation.
    count = if survived?(last_respawn, now, state.min_uptime), do: 0, else: raw_count

    if count < @max_attempts do
      if raw_count >= @max_attempts do
        Logger.warning(
          "PermanentWarden: permanent #{role} died AFTER HALT (external repair detected) → " <>
            "new respawn cycle"
        )
      end

      delay = backoff_delay(count, state.base)

      Logger.warning(
        "PermanentWarden: permanent #{role} dead → respawn in #{div(delay, 1000)}s " <>
          "(attempt #{count + 1}/#{@max_attempts})"
      )

      Process.send_after(self(), {:respawn, role}, delay)

      {:noreply,
       %{
         state
         | attempts: Map.put(state.attempts, role, {count + 1, nil}),
           pending: MapSet.put(state.pending, role)
       }}
    else
      # Keep the timestamp; a later scheduling request may reset the budget.
      Logger.error(
        "PermanentWarden: permanent #{role} boots then dies under #{div(state.min_uptime, 1000)}s " <>
          "with #{@max_attempts} attempts exhausted — HALT (sysadmin issue already opened by " <>
          "the incident rail; intervention required)"
      )

      {:noreply, state}
    end
  end

  defp survived?(nil, _now, _min_uptime), do: true
  defp survived?(last_ms, now, min_uptime), do: now - last_ms >= min_uptime

  @doc "Capped exponential backoff: base * 2^attempt, cap #{@max_delay_ms} ms. Pure (testable)."
  @spec backoff_delay(non_neg_integer(), pos_integer()) :: pos_integer()
  def backoff_delay(attempt, base_ms)
      when is_integer(attempt) and attempt >= 0 and is_integer(base_ms) and base_ms > 0 do
    import Bitwise, only: [<<<: 2]
    min(base_ms * (1 <<< min(attempt, 20)), @max_delay_ms)
  end
end
