defmodule Fleet.Spawner.PermanentWarden do
  @moduledoc """
  Respawn of dead PERMANENT pods (cattle, rebuildable) — Bus consumer of `pod.failed`.

  A permanent pod (`permanent-<role>`: architect, gatekeeper, …) is `restart: :temporary` on the OTP
  side (like every pod: the respawn is EVENT-driven, not supervisor-driven — a bare OTP restart would
  relaunch the gen_statem without the clean boot sequence). Before this module, its death was a
  DEFINITIVE stop until the BEAM restart: the only safety net was the gatekeeper's implicit reboot at
  the next escalation kick — a dead archivist/architect stayed silently absent.

  ## Mechanics

  `pod.failed` from a `permanent-*` pod → respawn SCHEDULED with capped exponential backoff, via
  `PermanentBoot.respawn/2` (the SAME path as boot: deterministic idempotent pod_id + boot-from-base
  = FRESH context from the versioned base — never the dead pod's accumulated session).

  ## BOUNDED spend (the failure mode = spend, never a churn)

  Each successful respawn boots a claude session: an unbounded crash-loop would burn LLM in a loop.
  So the retry is BOUNDED: `@max_attempts` consecutive attempts per role (exponential backoff
  `base * 2^attempt` capped at 10 min — default base 5s, i.e. 5s → 10s → 20s → 40s → 80s),
  counter reset on a SUCCESSFUL respawn. Exhausted → retry HALT + `Logger.error`
  (the role stays dead until intervention). This halt is NOT silent: the human escalation has
  ALREADY gone through the incident rail (`IncidentConsumer` records every `pod.failed`; the RECURRENCE
  of the same signature opens an `error_system` sysadmin issue on the forge — a repaired rail) — so the
  warden carries NO escalation wiring of its own (composition, not an authority fork).

  ## Seams (tests)

    * `:subscribe` (default true) — real Bus subscription.
    * `:respawn_fun` (default `&Fleet.Spawner.PermanentBoot.respawn/1`) — `(role) -> {:ok, pod_id} | {:error, _}`.
    * `:backoff_base_ms` (default 5_000) — backoff base (reduced in test).
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
    {:ok, %{respawn_fun: respawn_fun, base: base, attempts: %{}}}
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
        Logger.info("PermanentWarden: permanent #{role} respawne (#{pod_id})")
        # Respawn SUCCESSFUL → counter reset (a LATER death restarts from a short backoff).
        {:noreply, %{state | attempts: Map.delete(state.attempts, role)}}

      {:error, reason} ->
        # Failure of the spawn ITSELF (not a pod death): no pod.failed emitted to re-arm the cycle →
        # we re-schedule HERE, same counter/backoff as via the event (a single mechanism).
        attempt = Map.get(state.attempts, role, 1)

        if attempt < @max_attempts do
          delay = backoff_delay(attempt, state.base)

          Logger.warning(
            "PermanentWarden: respawn #{role} ECHOUE (#{inspect(reason)}) → retry dans " <>
              "#{div(delay, 1000)}s (tentative #{attempt + 1}/#{@max_attempts})"
          )

          Process.send_after(self(), {:respawn, role}, delay)
          {:noreply, %{state | attempts: Map.put(state.attempts, role, attempt + 1)}}
        else
          Logger.error(
            "PermanentWarden: respawn #{role} — #{@max_attempts} echecs consecutifs, HALT " <>
              "(issue sysadmin deja ouverte par le rail incident ; intervention requise)"
          )

          {:noreply, state}
        end
    end
  end

  # Any other event / message → no-op (filtering consumer, like PublishConsumer).
  def handle_info(_other, state), do: {:noreply, state}

  defp handle_permanent_death(role, state) do
    attempt = Map.get(state.attempts, role, 0)

    if attempt < @max_attempts do
      delay = backoff_delay(attempt, state.base)

      Logger.warning(
        "PermanentWarden: permanent #{role} mort → respawn dans #{div(delay, 1000)}s " <>
          "(tentative #{attempt + 1}/#{@max_attempts})"
      )

      Process.send_after(self(), {:respawn, role}, delay)
      {:noreply, %{state | attempts: Map.put(state.attempts, role, attempt + 1)}}
    else
      # Bound reached BUT a POST-HALT pod.failed proves a pod of this role HAS LIVED AGAIN since
      # (it had to live to die: the warden no longer respawns after HALT → this is an
      # external/manual repair). Cattle: this new failure deserves a NEW cycle of retries —
      # without a reset, the warden stayed dead for this role until the BEAM restart. No loop:
      # each post-HALT cycle requires an external resurrection (the spend is borne by the actor).
      Logger.warning(
        "PermanentWarden: permanent #{role} mort APRES HALT (reparation externe detectee) → " <>
          "nouveau cycle de respawn (compteur remis a zero)"
      )

      delay = backoff_delay(0, state.base)
      Process.send_after(self(), {:respawn, role}, delay)
      {:noreply, %{state | attempts: Map.put(state.attempts, role, 1)}}
    end
  end

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
