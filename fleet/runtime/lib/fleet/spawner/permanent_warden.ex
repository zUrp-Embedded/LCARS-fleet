defmodule Fleet.Spawner.PermanentWarden do
  @moduledoc """
  Respawn of dead PERMANENT pods (cattle, rebuildable) — Bus consumer of `pod.failed`.

  A permanent pod (`permanent-<role>`: architect, gatekeeper, …) is `restart: :temporary` on the OTP
  side (like every pod: the respawn is EVENT-driven, not supervisor-driven — a bare OTP restart would
  relaunch the gen_statem without the clean boot sequence). Before this module, its death was a
  DEFINITIVE stop until the BEAM restart: the only safety net was the gatekeeper's implicit reboot at
  the next escalation kick — a dead archivist/architect stayed silently absent.

  ## Mechanics — two rails, one respawn path

  1. **Event** (`pod.failed` of a `permanent-*` pod) → respawn SCHEDULED with capped exponential
     backoff, via `PermanentBoot.respawn/2` (the SAME path as boot: deterministic idempotent
     pod_id + boot-from-base = FRESH context from the versioned base — never the dead pod's
     accumulated session).
  2. **Reconciliation tick** — the event rail is BLIND to a permanent that dies WITHOUT emitting:
     a restart of the spawner sub-tree terminates its `:temporary` pods CLEANLY (no `pod.failed`),
     the BootOrchestrator is one-shot at boot, and the Bus is lossy by doctrine. The permanents
     would stay dead, silently, until an escalation. So the warden also RE-DERIVES the truth
     periodically: expected permanents (`PermanentBoot.select_permanent`) vs the live Registry —
     any missing one is respawned through the SAME counter/backoff (a reconciliation cannot spend
     more than the event rail). The tick is a no-op when the permanent boot is disabled
     (`LCARS_BOOT_PERMANENT_AT_START=false` — the documented maintenance mode is respected).
     During a drain, the quiesce gate is expected to live at the mechanical chokepoint
     (`Fleet.Spawner.spawn_pod` — open arbitration A-13), which covers this tick for free; the
     seam `:reconcile_enabled_fun` composes it meanwhile.

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
  Boot gate: `:fleet_spawner, :start_permanent_warden` (default true prod, false test — hermeticity).
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus

  # Spend bounds: 5 consecutive attempts max per role, exponential backoff capped at 10 min.
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
      # attempts: role => {count, last_respawn_mono_ms | nil} — count = consecutive attempts,
      # stamp = last WARDEN respawn ({:ok, _} from respawn_fun; nil when the last attempt failed
      # or none happened). Monotonic clock: wall-clock jumps must not fake a survival.
      attempts: %{}
    }

    :ok = schedule_reconcile(reconcile_ms)

    {:ok, state}
  end

  @impl true
  # Death of a PERMANENT pod → schedules the respawn (backoff per the role's counter). Non-permanent
  # pods (issue-*, pr-*) do not match the prefix → catch-all no-op (their relaunch is the forge rail's
  # job: reconciliation + re-dispatch).
  def handle_info(
        %Fleet.Event{source: :spawner, type: :"pod.failed", payload: %{"pod_id" => pod_id}},
        state
      )
      when is_binary(pod_id) do
    # Permanent prefix: AUTHORITY = PermanentBoot.parse_permanent/1 (the literal no longer lives here).
    case Fleet.Spawner.PermanentBoot.parse_permanent(pod_id) do
      :not_permanent ->
        {:noreply, state}

      {:ok, role} ->
        handle_permanent_death(role, state)
    end
  end

  def handle_info({:respawn, role}, state) do
    # respawn_fun is rescue-wrapped — a raise (cap-profile bug, FS) would kill the warden
    # (loss of counters + pending timers → roles dead silently after an empty restart).
    result =
      try do
        state.respawn_fun.(role)
      rescue
        e -> {:error, {:respawn_raised, Exception.message(e)}}
      end

    case result do
      {:ok, pod_id} ->
        Logger.info("PermanentWarden: permanent #{role} respawned (#{pod_id})")

        # NO counter reset here: `{:ok, pid}` = start_child accepted — the async allocate→launch
        # chain has not run yet (a boot-then-die pod would loop forever on a reset-at-start).
        # We STAMP the respawn instant; the reset happens at the NEXT death IF the pod lived
        # past `min_uptime` (observed survival), lazily in `handle_permanent_death/2`.
        now = System.monotonic_time(:millisecond)

        attempts =
          Map.update(state.attempts, role, {0, now}, fn {count, _} -> {count, now} end)

        {:noreply, %{state | attempts: attempts}}

      {:error, reason} ->
        # Failure of the spawn ITSELF (not a pod death): no pod.failed emitted to re-arm the cycle →
        # we re-schedule HERE, same counter/backoff as via the event (a single mechanism).
        {attempt, _stamp} = Map.get(state.attempts, role, {1, nil})

        if attempt < @max_attempts do
          delay = backoff_delay(attempt, state.base)

          Logger.warning(
            "PermanentWarden: respawn #{role} FAILED (#{inspect(reason)}) → retry in " <>
              "#{div(delay, 1000)}s (attempt #{attempt + 1}/#{@max_attempts})"
          )

          Process.send_after(self(), {:respawn, role}, delay)
          {:noreply, %{state | attempts: Map.put(state.attempts, role, {attempt + 1, nil})}}
        else
          Logger.error(
            "PermanentWarden: respawn #{role} — #{@max_attempts} consecutive failures, HALT " <>
              "(sysadmin issue already opened by the incident rail; intervention required)"
          )

          {:noreply, state}
        end
    end
  end

  # RECONCILIATION tick — re-derives the truth instead of waiting for an event that may never
  # come (a cleanly-terminated pod emits no `pod.failed`; the Bus is lossy). Expected permanents
  # vs live Registry: the missing ones go through the SAME respawn path (counter/backoff shared
  # with the event rail → a reconciliation can never spend more than an event storm would).
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
      # Permanent boot disabled (maintenance) or fleet quiescing (drain): re-deriving would fight
      # the operator's own intent. The tick keeps ticking — the gate is a state, not a stop.
      {:noreply, state}
    end
  end

  # Any other event / message → no-op (filtering consumer, like PublishConsumer).
  def handle_info(_other, state), do: {:noreply, state}

  # Expected − live, computed defensively: an enumeration that raises (Registry unavailable,
  # catalogue unreadable) must never kill the warden nor — worse — report EVERY permanent as
  # missing and respawn the whole fleet. A failed reconciliation yields NOTHING to respawn: the
  # tick is a safety net, it never becomes a hazard of its own.
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

  # Same counter/backoff/HALT as the event rail (single mechanism — `handle_permanent_death/2`):
  # a role already exhausted stays HALTed, a reconciliation does not re-arm the spend.
  defp schedule_respawn(role, state) do
    {:noreply, new_state} = handle_permanent_death(role, state)
    new_state
  end

  # Single authority for "who is permanent" — the SAME selection the boot uses (no fork of the
  # `boot_at_start?` rule here).
  defp default_expected_roles, do: Fleet.Spawner.PermanentBoot.expected_permanent_roles()

  # Arme le tick suivant. `nil` = réconciliation désactivée (seam de test). Le timer ref n'est
  # jamais annulé (le tick se re-programme lui-même) → valeur sans signification, jetée ici plutôt
  # qu'au site d'appel (dialyzer strict : unmatched_return).
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

  # Gate of the reconciliation tick. `auto_boot_enabled?` ONLY: the maintenance mode
  # (`LCARS_BOOT_PERMANENT_AT_START=false`) must not be defeated by a warden re-deriving pods
  # nobody asked for.
  #
  # NOT gated on `Shutdown.Quiesce.quiescing?` here, deliberately: `Fleet.Spawner` does not declare
  # `Fleet.Shutdown` in its boundary, and wiring that edge IS the open arbitration A-13
  # (quiesce at the mechanical chokepoint — `spawn_pod` — rather than sprinkled per caller).
  # The day A-13 lands, the chokepoint covers this tick for free. Until then the seam
  # `:reconcile_enabled_fun` lets a caller compose the check without widening the boundary.
  defp default_reconcile_enabled?, do: Fleet.Spawner.PermanentBoot.auto_boot_enabled?()

  defp handle_permanent_death(role, state) do
    now = System.monotonic_time(:millisecond)
    {raw_count, last_respawn} = Map.get(state.attempts, role, {0, nil})

    # Survival OBSERVED = the pod lived past min-uptime since the last WARDEN respawn — or no
    # warden respawn stamp at all (nil / stale = an EXTERNAL actor booted the pod that just
    # died: it had to live to die, and the warden wasn't the one paying). Only that resets the
    # cycle; a death under min-uptime CONTINUES the counter (boot-then-die is one crash-loop,
    # not five fresh incidents).
    count = if survived?(last_respawn, now, state.min_uptime), do: 0, else: raw_count

    if count < @max_attempts do
      if raw_count >= @max_attempts do
        # Post-HALT death with survival observed = external/manual repair (the warden no longer
        # respawns after HALT). Cattle: new cycle — the resurrection spend was borne by the actor.
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
      {:noreply, %{state | attempts: Map.put(state.attempts, role, {count + 1, nil})}}
    else
      # Crash-loop CONFIRMED: died under min-uptime with the bound exhausted → REAL, durable
      # HALT (no re-arm; the spend stops HERE). The stamp stays: a much later death (external
      # resurrection that lived past min-uptime) passes `survived?/3` above → fresh cycle.
      Logger.error(
        "PermanentWarden: permanent #{role} boots then dies under #{div(state.min_uptime, 1000)}s " <>
          "with #{@max_attempts} attempts exhausted — HALT (sysadmin issue already opened by " <>
          "the incident rail; intervention required)"
      )

      {:noreply, state}
    end
  end

  # nil stamp = the last warden attempt failed before launching anything (or never happened):
  # the pod that just died was necessarily booted OUTSIDE the warden → counts as survival
  # (external repair), never as a warden crash-loop iteration.
  defp survived?(nil, _now, _min_uptime), do: true
  defp survived?(last_ms, now, min_uptime), do: now - last_ms >= min_uptime

  @doc "Capped exponential backoff: base * 2^attempt, cap #{@max_delay_ms} ms. Pure (testable)."
  @spec backoff_delay(non_neg_integer(), pos_integer()) :: pos_integer()
  def backoff_delay(attempt, base_ms)
      when is_integer(attempt) and attempt >= 0 and is_integer(base_ms) and base_ms > 0 do
    # TYPED guards (`> 0` alone let a float through → the whole computation became float,
    # the spec lied) + shift `1 <<< n` (Integer.pow's type includes a float path).
    import Bitwise, only: [<<<: 2]
    min(base_ms * (1 <<< min(attempt, 20)), @max_delay_ms)
  end
end
