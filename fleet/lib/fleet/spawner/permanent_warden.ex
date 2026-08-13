defmodule Fleet.Spawner.PermanentWarden do
  @moduledoc """
  Respawn of dead PERMANENT pods (cattle, rebuildable) — Bus consumer of `pod.failed`.

  A permanent pod (`permanent-<role>`: architect, gatekeeper, …) is `restart: :temporary` on the OTP
  side (like every pod: the respawn is EVENT-driven, not supervisor-driven — a bare OTP restart would
  relaunch the gen_statem without the clean boot sequence). Without this module, its death would be
  a DEFINITIVE stop until the BEAM restart — a dead archivist/architect silently absent.

  ## Mechanics — two rails, one respawn path

  1. **Event** (`pod.failed` of a `permanent-*` pod) → respawn SCHEDULED with capped exponential
     backoff, via `PermanentBoot.respawn/2` (the SAME path as boot: deterministic idempotent
     pod_id + a FRESH context (recreated from scratch, no base seed) — never the dead pod's
     accumulated session).
  2. **Reconciliation tick** — the event rail is BLIND to a permanent that dies WITHOUT emitting:
     a restart of the spawner sub-tree terminates its `:temporary` pods CLEANLY (no `pod.failed`),
     the BootOrchestrator is one-shot at boot, and the Bus is lossy by doctrine. The permanents
     would stay dead, silently, until an escalation. So the warden also RE-DERIVES the truth
     periodically: expected permanents (`PermanentBoot.select_permanent`) vs the live Registry —
     any missing one is respawned through the SAME counter/backoff (a reconciliation cannot spend
     more than the event rail). The tick is a no-op when the permanent boot is disabled
     (`LCARS_BOOT_PERMANENT_AT_START=false` — the documented maintenance mode is respected).
     During a drain, the quiesce gate LIVES at the mechanical chokepoint (`Fleet.Spawner.spawn_pod`
     — A-13 decided 2026-08-05), which covers this tick for free. The composition below stays: it
     spares a pointless reconcile pass, and it is now belt over braces rather than the only strap.
     The arbitration mattered because the warden was one of only TWO readers of `quiescing?/0` —
     the poller's dispatch was not, so a drain could keep spawning fresh pods it then had to wait
     for.

  ## BOUNDED spend (the failure mode = spend, never a churn)

  Each successful respawn boots a claude session: an unbounded crash-loop would burn LLM in a loop.
  So the retry is BOUNDED: `@max_attempts` consecutive attempts per role (exponential backoff
  `base * 2^attempt` capped at 10 min — default base 5s, i.e. 5s → 10s → 20s → 40s → 80s).
  The counter resets ONLY on OBSERVED survival: the pod must live past `:min_uptime_ms` after
  a warden respawn. A `start_child` `{:ok, pid}` proves NOTHING (the allocate→launch chain is
  async) — resetting there let a boot-then-die pod loop forever at ~5s with the HALT unreachable
  and the spend unbounded, the exact failure mode this bound exists for. Exhausted → retry HALT
  + `Logger.error` (the role stays dead until intervention). This halt is NOT silent: the human
  escalation has ALREADY gone through the incident rail (`IncidentConsumer` records every
  `pod.failed`; the RECURRENCE of the same signature opens an `error_system` sysadmin issue on
  the forge — a repaired rail) — so the warden carries NO escalation wiring of its own
  (composition, not an authority fork). A death with a STALE respawn stamp (or none) means an
  external actor resurrected the role since — that IS the external repair signal: new cycle,
  the spend was borne by the actor (cattle, E2).

  ## Seams (tests)

    * `:subscribe` (default true) — real Bus subscription.
    * `:respawn_fun` (default `&Fleet.Spawner.PermanentBoot.respawn/1`) — `(role) -> {:ok, pod_id} | {:error, _}`.
    * `:backoff_base_ms` (default 5_000) — backoff base (reduced in test).
    * `:min_uptime_ms` (default 60_000) — survival threshold that resets the attempt counter.
    * `:reconcile_ms` (default 60_000) — cadence of the reconciliation tick; `nil` disables it.
    * `:expected_roles_fun` — `() -> [role]` (default = the permanent roles of the catalogue).
    * `:live_roles_fun` — `() -> [role]` (default = the `permanent-*` pods live in the Registry).
    * `:reconcile_enabled_fun` — `() -> boolean` (default = permanent-boot on AND not quiescing).
  Boot gate: `:lcars_fleet, :spawner_start_permanent_warden` (default true prod, false test — hermeticity).
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus

  # Per-role spend bound.
  @max_attempts 5
  @max_delay_ms 600_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()
    respawn_fun = Keyword.get(opts, :respawn_fun, &Fleet.Spawner.PermanentBoot.respawn/1)
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
      # F-01: one in-flight timer per role.
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
    case Fleet.Spawner.PermanentBoot.parse_permanent(pod_id) do
      :not_permanent ->
        {:noreply, state}

      {:ok, role} ->
        handle_permanent_death(role, state)
    end
  end

  def handle_info({:respawn, role}, state) do
    # F-01
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

        # Launch acceptance stamps the attempt; only later survival resets it.
        now = System.monotonic_time(:millisecond)

        attempts =
          Map.update(state.attempts, role, {0, now}, fn {count, _} -> {count, now} end)

        {:noreply, %{state | attempts: attempts}}

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

  # Reconciliation covers clean termination and lossy events through the same bound.
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

  defp default_expected_roles, do: Fleet.Spawner.PermanentBoot.expected_permanent_roles()

  defp schedule_reconcile(ms) when is_integer(ms) do
    _ = Process.send_after(self(), :reconcile, ms)
    :ok
  end

  defp schedule_reconcile(_), do: :ok

  defp default_live_roles do
    Fleet.Spawner.list_pods()
    |> Enum.flat_map(fn pod ->
      case Fleet.Spawner.PermanentBoot.parse_permanent(pod[:pod_id] || "") do
        {:ok, role} -> [role]
        :not_permanent -> []
      end
    end)
  end

  # Maintenance and quiesce suppress desired-state reconciliation.
  defp default_reconcile_enabled? do
    Fleet.Spawner.PermanentBoot.auto_boot_enabled?() and not Fleet.Shutdown.Quiesce.quiescing?()
  end

  defp handle_permanent_death(role, state) do
    # F-01
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

    # No/stale warden stamp denotes external repair; short-lived launches stay one cycle.
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
      # Preserve the stamp so later observed external repair can open a fresh cycle.
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
