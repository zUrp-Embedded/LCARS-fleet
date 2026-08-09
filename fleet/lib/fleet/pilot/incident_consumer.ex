defmodule Fleet.Pilot.IncidentConsumer do
  @moduledoc """
  Bus consumer of **pod FAILURE** events (`pod.failed` / `wake.failed` / `spawn.failed`, source
  `:spawner`) → `Fleet.Pilot.IncidentRegistry` (note on 1st / escalate on recurrent). Subscribes
  `Fleet.EventRouter.Bus` (topic `fleet.events`).

  ## Why a consumer SEPARATE from the StepRunConsumer

  Pod failures are a **distinct** concern from step-run-end (completion): they touch neither the
  workflow_map, nor the gate, nor the completion state — just "this incident, 1st or recurrent?" → registry.
  Both handlers are **stateless** (they read no state of the consumer). Isolating them in their
  own singleton: (a) the StepRunConsumer (completion singleton) does not carry a 2nd
  bolted-on responsibility, (b) a burst of failures does not share the completion path's mailbox (reduced
  blast-radius). The escalation POLICY (1st=note / recurrent=root-cause, kinds, labels) lives in
  `IncidentRegistry`; this module only **routes the event to it**.

  ## Escalation decision (delegated to `IncidentRegistry`)

    * `pod.failed` — a failed pod (`transition_failed`: result_timeout/dead-REPL, allocate/launch/
      auth/project). 1st = noted (tolerated, possibly random); recurrent = escalated (pattern → root-cause).
    * `wake.failed` — the ack-driven loop exhausted the cap (the agent NEVER acked: neither flag, nor
      send-keys). Recurrence = **SP suspect** (inference targets the SP, not the agent: 1×=random, recurrent
      = bad/drifted SP) → `escalate_kind: :sp_suspect` (+ `pane` for the diag).
    * `spawn.failed` — the `admin.spawn.request` dispatch DROPPED the spawn AFTER the API answered 202
      (no pod created → no pod_id). Subject = `cap_profile_name` (the role: recurrence = "this role keeps
      failing to spawn"; issue_id is per-request → never recurs). op="spawn", default recurrence escalation.

  ## Cat-5 (source `:starfleet`) — MAX severity, DIRECT escalation (A-06)

  `starfleet.audit_cat5_<pod_drift|workflow_map_failed|oauth_refresh_failed>` — the max-severity
  rail (`Cat5Escalator`). Without this route it would only leave a LOCAL NDJSON line + two lossy
  Bus broadcasts: the LOW-severity incident rail opens a durable forge issue while the
  MAX-severity one evaporates if nobody tails the file (severity/durability inversion). Routed
  here to the SAME durable forge sink — via `IncidentRegistry.escalate_gated/5` (issue on FIRST
  occurrence, label `error_cat5`): max severity is not sampled by a recurrence gate — only the
  REPEATS of the same signature under the registry cooldown are suppressed (the open issue
  carries the alarm; a permanent drift does not re-create one issue per event). The event's
  `correlation_id` links the issue back to the causing mandate. No new compile dep:
  the event is plain data on the Bus, its 3 atoms are registry-declared.

  ## Offload (`:runner`)

  `record_or_escalate` touches the forge (registry read/write) → OFFLOAD into a
  `Task.Supervisor` so as not to block the consumer's mailbox on a burst of failures. Seam `:runner`:
  default `nil` → **SYNC** (the outcome is logged inline; deterministic tests without injection). Prod
  (`application.ex`) injects `&offload_async/1` → supervised async (a `record` that crashes is isolated).

  ## Config / seams

    * `:subscribe` — bool default `true` (tests: `false` + manual sending via `send/2`).
    * `:record_fun` — `fn op, subject, reason, opts -> :recorded | {:escalated|…, _} end`
      (default `&Fleet.Pilot.IncidentRegistry.record_or_escalate/4`). Test seam (zero forge).
    * `:escalate_fun` — `fn kind, subject, reason, sig, opts -> {:ok, n} | {:suppressed, n} | {:error, _} end`
      (default `&Fleet.Pilot.IncidentRegistry.escalate_gated/5`). Cat-5 path: 1st occurrence
      immediate, repeats under the registry cooldown suppressed.
    * `:runner` — offload seam (see above). Default `nil` → sync.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  # Task supervisor for the offload (prod). Name shared between `application.ex` (which starts it BEFORE
  # this consumer) and `offload_async/1`. Specific to this consumer (not the StepRunConsumer's): clean separation.
  @task_supervisor Fleet.Pilot.IncidentConsumer.TaskSupervisor

  defstruct record_fun: nil, escalate_fun: nil, runner: nil, routing_fun: nil, brake_fun: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc false
  def task_supervisor, do: @task_supervisor

  # Saturation runs inline: incident memory is never dropped.
  @doc false
  def offload_async(fun) do
    Fleet.Pilot.Offload.async_or_inline(
      @task_supervisor,
      fun,
      {"IncidentConsumer", "incident NOT recorded"}
    )
  end

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()

    state = %__MODULE__{
      record_fun:
        Keyword.get(opts, :record_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4),
      escalate_fun:
        Keyword.get(opts, :escalate_fun, &Fleet.Pilot.IncidentRegistry.escalate_gated/5),
      runner: Keyword.get(opts, :runner),
      brake_fun: Keyword.get(opts, :brake_fun, &__MODULE__.default_brake/3),
      # The event → op/escalation-kind CLASSIFICATION is TABLE data (`events.yaml` routing —
      # audit B-05); the seam keeps the unit tests hermetic (no global persistent_term mutation).
      routing_fun: Keyword.get(opts, :routing_fun, &Fleet.EventRouter.Bus.event_routing/0)
    }

    {:ok, state}
  end

  @impl GenServer
  # TABLE-DRIVEN consumer (audit B-05): which event becomes WHICH incident class — op, subject key,
  # escalation kind, forwarded diag keys — is DATA (`events.yaml` routing), this module is the
  # MECHANIC. Adding an incident class is a registry edit, not a new clause. Actions owned here:
  # `incident` (recurrence-gated recording) and `incident_cat5` (direct escalation, max severity —
  # the tag derived from the synthesized `starfleet.audit_cat5_<tag>` type). Other actions belong
  # to other mechanics (DriftMonitor) and are ignored, as are unrouted events.
  def handle_info(%Fleet.Event{source: source, type: type, payload: p} = ev, state) do
    case Map.get(state.routing_fun.(), {source, type}) do
      %{action: :incident, incident: inc} ->
        handle_incident(state, inc, p, ev)

      %{action: :incident_cat5} ->
        escalate_cat5(state, cat5_tag(type), ev)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # BEFORE the catch-all: the death of an OFFLOADED record/escalate task (Offload monitors it;
  # the :DOWN lands here). Same witness rule as StepRunConsumer — a recording task dying mid-work
  # must leave a loud trace, not vanish into the catch-all.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    _ = Fleet.Pilot.Offload.handle_down(ref, pid, reason)
    {:noreply, state}
  end

  # Any other message (non-failure events we also see via the Bus, or non-Fleet.Event) → no-op.
  def handle_info(_other, state), do: {:noreply, state}

  # Routes the incident to the registry, offloaded via `:runner` (default sync). The 4-tuple
  # `(op, subject, reason, opts)` is the contract of `IncidentRegistry.record_or_escalate/4` (`op="pod"` →
  # `opts=[]`; `op="wake"` → `escalate_kind:/pane:`). The outcome is logged (never swallowed): an
  # unrecorded incident / a failed escalation must be VISIBLE (forge down? registry unavailable?).
  # Applies one `incident` route: subject from the DECLARED payload key, universal mechanics
  # (reason/reason_detail/correlation_id) + declared extras (escalate_kind, forwarded diag keys —
  # e.g. wake's `pane`). A routed event whose subject key is missing is a PRODUCER bug: named
  # LOUD, never recorded under a nil subject (the dedup signature would collapse).
  defp handle_incident(state, inc, payload, ev) do
    case Map.get(payload, inc.subject) do
      subject when is_binary(subject) ->
        reg_opts =
          [
            reason_detail: payload["reason_detail"],
            correlation_id: ev.correlation_id
          ] ++
            if(inc.escalate_kind, do: [escalate_kind: inc.escalate_kind], else: []) ++
            for key <- inc.forward, do: {key, payload[Atom.to_string(key)]}

        record(state, inc.op, subject, payload["reason"], reg_opts, payload)

      _ ->
        Logger.warning(
          "IncidentConsumer: routed incident #{ev.type} carries no #{inspect(inc.subject)} " <>
            "subject — producer bug, NOT recorded (a nil subject would collapse the dedup signature)"
        )
    end
  end

  # The Cat-5 tag from the synthesized broadcast type (`starfleet.audit_cat5_<tag>` — the
  # registered key the routing's cat5 route was validated against at boot).
  defp cat5_tag(type),
    do: type |> Atom.to_string() |> String.replace_prefix("starfleet.audit_cat5_", "")

  defp record(state, op, pod_id, reason, reg_opts, payload) do
    exec = fn ->
      case state.record_fun.(op, pod_id, reason, reg_opts) do
        :recorded ->
          Logger.info(
            "IncidentConsumer: #{op}.failed #{pod_id} → incident recorded (#{inspect(reason)})"
          )

        {:escalated, _} ->
          Logger.warning(
            "IncidentConsumer: #{op}.failed #{pod_id} RECURRENT → escalated (#{inspect(reason)})"
          )

          maybe_brake(state, op, reason, payload)

        {:escalation_failed, e} ->
          Logger.error(
            "IncidentConsumer: #{op}.failed #{pod_id} RECURRENT but escalation FAILED — NO sysadmin " <>
              "issue created (forge down?): #{inspect(e)}"
          )

        {:recorded_volatile, e} ->
          Logger.error(
            "IncidentConsumer: #{op}.failed #{pod_id}: incident in MEMORY only — WAL write FAILED " <>
              "(#{inspect(e)}): NOT durable cross-session until the async forge sync absorbs it " <>
              "(a crash before the sync would lose the recurrence)"
          )

        {:record_failed, e} ->
          Logger.error(
            "IncidentConsumer: #{op}.failed #{pod_id}: incident NOT recorded (registry unavailable): #{inspect(e)}"
          )

        {:escalation_suppressed, issue} ->
          # Recurrence under cooldown: noted at the registry (count/last_seen), the existing issue
          # carries the alarm — :debug (a durable failure recurs at EVERY tick, one warning per
          # tick would drown the trace the open issue already covers).
          Logger.debug(
            "IncidentConsumer: #{op}.failed #{pod_id} recurrent under cooldown — noted, " <>
              "existing issue #{inspect(issue)} carries the alarm"
          )

          # The brake applies UNDER COOLDOWN too: the suppression concerns the SYSADMIN ISSUE (not
          # opening one per tick), NOT the re-dispatch loop. Braking only on `{:escalated, _}` would
          # let the ticket restart forever from the second recurrence on.
          maybe_brake(state, op, reason, payload)

        other ->
          Logger.warning(
            "IncidentConsumer: #{op}.failed #{pod_id} → unexpected outcome #{inspect(other)}"
          )
      end
    end

    (state.runner || (&run_sync/1)).(exec)
  end

  # ─── LE FREIN (BL-6-37.6) ────────────────────────────────────────────────────────────────────
  # The incident rail already KNEW "recurrence" — its sysadmin issue says "Deja vu — ROOT-CAUSE
  # required" — and the poller re-dispatched anyway, forever. Measured 2026-08-02 on the tetris
  # bench: a producer killed mid-writing, respawned in a loop, invisible on its own ticket.
  # Detecting without unplugging builds a damage counter, not a brake.
  #
  # The missing consequence: put `lcars-awaits-arch` on the WORK TICKET. The vocabulary exists and
  # does exactly the right thing — the poller takes an issue carrying it OUT of dispatch, and a
  # human/the arch decides. We do not kill, we do not retry harder: we hand back.
  #
  # ⚠ RESTRICTED to the timeout, deliberately. The entry measures `result_timeout` — a loop where
  # the pod is working and gets cut. Braking on ANY recurrent category would pull tickets out of
  # dispatch for causes nobody measured here (an `exited_before_result` can be a brief error that a
  # rework fixes). Widening happens on a measurement, not on an intuition.
  defp maybe_brake(state, "pod", reason, payload) when is_map(payload) do
    with true <- timeout_reason?(reason),
         repo when is_binary(repo) <- payload["repo"],
         {:ok, number} <- Fleet.Pilot.IssueId.parse(payload["issue_id"] || "") do
      state.brake_fun.(repo, number, reason)
    else
      _ -> :ok
    end
  end

  defp maybe_brake(_state, _op, _reason, _payload), do: :ok

  # The category normalised producer-side (`Fleet.Event.reason_fields/1`) — we compare on the
  # STABLE shape, never on the original tuple, which does not cross the bus.
  defp timeout_reason?(reason), do: to_string(reason) =~ "result_timeout"

  @doc false
  # Best-effort BY OBLIGATION: a brake that cannot be placed must not break the incident rail,
  # which is itself the rail of last resort. Failure is said LOUD — without that, we would have a
  # silently absent brake, which is worse than no brake at all (you would believe you are covered).
  def default_brake(repo, number, reason) do
    forge = Application.get_env(:fleet_pilot, :forge_client, Fleet.Forge.Client)

    case forge.add_label(repo, number, Fleet.Labels.awaits_arch(), []) do
      {:ok, _} ->
        Logger.warning(
          "IncidentConsumer: FREIN — #{repo}##{number} sort du dispatch (#{inspect(reason)} " <>
            "recurrent) : `#{Fleet.Labels.awaits_arch()}` pose, l'arch tranche"
        )

        clear_in_flight(forge, repo, number)
        :ok

      {:error, e} ->
        Logger.error(
          "IncidentConsumer: FREIN NON POSE sur #{repo}##{number} (#{inspect(e)}) — le ticket " <>
            "reste dans la boucle de re-dispatch"
        )

        :ok
    end
  rescue
    e ->
      Logger.error("IncidentConsumer: FREIN a leve sur #{repo}##{number} : #{inspect(e)}")
      :ok
  end

  # THE BRAKE IS TWO GESTURES, NOT ONE — and the second is what makes the first hold.
  #
  # `awaits-arch` takes the ticket out of dispatch. It does NOT release the in-flight lock, and a
  # lock left on a ticket nobody can advance is not inert: the poller's reconciliation finds it
  # orphaned (no live pod), reclaims it, and re-dispatches — a fresh pod goes and blocks in the
  # same place. Observed on the bench 2026-08-09, and only closing the ticket by hand stopped it.
  # So the two labels must never coexist, and every site that sets one clears the other
  # (`labels.awaits_arch_clears_in_flight` in `mix lcars.contracts.check` holds all three).
  #
  # A bare `remove_label` and not `StepRunCompleter.unlock/6`, deliberately: unlock also stops the
  # ROLE's forge stopwatch and emits `step.unlocked`, and both need the role identity that took the
  # lock. This rail acts as the SYSTEM on a recurring incident — it does not know that identity and
  # will not guess it. What it therefore cannot do: the role's stopwatch keeps running through the
  # human wait, and this escalation produces no feed line.
  #
  # Best-effort like its sibling, and for the same reason: a brake that cannot be fully placed must
  # not break the rail of last resort. Failure is LOUD, because half a brake reads as a whole one.
  defp clear_in_flight(forge, repo, number) do
    case forge.remove_label(repo, number, Fleet.Labels.in_flight(), []) do
      {:ok, _} ->
        :ok

      {:error, e} ->
        Logger.error(
          "IncidentConsumer: FREIN pose mais `#{Fleet.Labels.in_flight()}` NON retire sur " <>
            "#{repo}##{number} (#{inspect(e)}) — le verrou orphelin sera repris par la " <>
            "reconciliation et le ticket re-dispatche malgre le frein"
        )

        :ok
    end
  end

  defp run_sync(fun), do: fun.()

  # Cat-5 → durable forge issue from the FIRST occurrence via `IncidentRegistry.escalate_gated/5`
  # (label `error_cat5`, sysadmin triage distinct from pod crashes) — no recurrence gate
  # on the 1st alarm (max severity, doctrine A-06); only the REPEATS of the same
  # signature under the registry cooldown are suppressed (the open issue carries the alarm —
  # without it, a permanent drift would re-create one issue per event). Offloaded like `record/5`
  # (touches the forge). A failed escalation is LOUD: losing the alarm would re-silence exactly
  # the evaporation this rail closes (the severity/durability inversion).
  defp escalate_cat5(state, source, %Fleet.Event{} = ev) do
    subject = ev.pod_id || source
    reason = extract_cat5_reason(ev.payload)
    sig = "cat5:#{source}:#{subject}"

    exec = fn ->
      case state.escalate_fun.(:cat5, subject, reason, sig,
             label: "error_cat5",
             correlation_id: ev.correlation_id
           ) do
        {:ok, number} ->
          Logger.warning(
            "IncidentConsumer: Cat-5 #{source} #{subject} → sysadmin issue ##{number} " <>
              "(error_cat5, 1st occurrence — immediate, no recurrence gate)"
          )

        {:suppressed, number} ->
          Logger.info(
            "IncidentConsumer: Cat-5 #{source} #{subject} recurrent under cooldown — " <>
              "existing issue #{inspect(number)} carries the alarm (recurrence noted)"
          )

        {:error, e} ->
          Logger.error(
            "IncidentConsumer: Cat-5 #{source} #{subject} escalation FAILED — NO durable issue " <>
              "(forge down?): #{inspect(e)} — the max-severity alarm is NOT engraved"
          )
      end
    end

    (state.runner || (&run_sync/1)).(exec)
  end

  defp extract_cat5_reason(%{"reason" => reason}), do: reason
  defp extract_cat5_reason(payload), do: payload
end
