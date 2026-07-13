defmodule Fleet.Pilot.IncidentConsumer do
  @moduledoc """
  Bus consumer of **pod FAILURE** events (`pod.failed` / `wake.failed` / `spawn.failed`, source
  `:spawner`) → `Fleet.Pilot.IncidentRegistry` (note on 1st / escalate on recurrent). Subscribes
  `Fleet.EventRouter.Bus` (topic `fleet.events`).

  ## Why a consumer SEPARATE from the StepRunConsumer

  Pod failures are a **distinct** concern from step-run-end (completion): they touch neither the
  workflow_map, nor the gate, nor the completion state — just « this incident, 1st or recurrent? » → registry.
  Both handlers are **stateless** (they read no state of the consumer). Isolating them in their
  own singleton: (a) the StepRunConsumer (completion singleton) no longer carries a 2nd
  bolted-on responsibility, (b) a burst of failures no longer shares the completion path's mailbox (reduced
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

  ## Cat-5 (source `:starfleet`) — MAX severity, DIRECT escalation (acte4 A-06)

  `starfleet.audit_cat5_<pod_drift|workflow_map_failed|oauth_refresh_failed>` — the max-severity
  rail (`Cat5Escalator`). Before this consumer it only left a LOCAL NDJSON line + two lossy Bus
  broadcasts: the LOW-severity incident rail opened a durable forge issue while the MAX-severity
  one evaporated if nobody tailed the file (severity/durability inversion). Routed here to the
  SAME durable forge sink — via `IncidentRegistry.escalate_gated/5` (issue on FIRST
  occurrence, label `error_cat5`): max severity is not sampled by a recurrence gate — only the
  REPEATS of the same signature under the registry cooldown are suppressed (the open issue
  carries the alarm; a permanent drift no longer re-creates one issue per event). The event's
  `correlation_id` (wave E) links the issue back to the causing mandate. No new compile dep:
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

  defstruct record_fun: nil, escalate_fun: nil, runner: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc false
  def task_supervisor, do: @task_supervisor

  # ASYNC runner (prod, injected as `:runner`) — offloads the record/escalate into the consumer's own
  # `Task.Supervisor`: the registry's forge does not block the mailbox. Returns `{:ok, :offloaded}`; spawn
  # failure → fail-loud logged (the incident is then NOT recorded — visible, not silent).
  # Shared skeleton `Fleet.Pilot.Offload` (single source); THIS consumer keeps its supervisor
  # and its loss consequence ("incident NOT recorded").
  @doc false
  def offload_async(fun),
    do:
      Fleet.Pilot.Offload.async(
        @task_supervisor,
        fun,
        {"IncidentConsumer", "incident NOT recorded"}
      )

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()

    state = %__MODULE__{
      record_fun:
        Keyword.get(opts, :record_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4),
      escalate_fun:
        Keyword.get(opts, :escalate_fun, &Fleet.Pilot.IncidentRegistry.escalate_gated/5),
      runner: Keyword.get(opts, :runner)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info(
        %Fleet.Event{source: :spawner, type: :"pod.failed", payload: %{"pod_id" => pod_id} = p} =
          ev,
        state
      )
      when is_binary(pod_id) do
    # `reason` = stable category (producer-normalized, keys the dedup signature) ;
    # `reason_detail` rides as an opt → engraved in the issue body by Escalation (human diag) ;
    # `correlation_id` (vague E) → bloc « Mandat lié » de l'issue de récurrence.
    record(state, "pod", pod_id, p["reason"],
      reason_detail: p["reason_detail"],
      correlation_id: ev.correlation_id
    )

    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{source: :spawner, type: :"wake.failed", payload: %{"pod_id" => pod_id} = p} =
          ev,
        state
      )
      when is_binary(pod_id) do
    # wake recurrence = SP suspect (see moduledoc) → typed escalation + `pane` for the diag.
    record(state, "wake", pod_id, p["reason"],
      escalate_kind: :sp_suspect,
      pane: p["pane"],
      reason_detail: p["reason_detail"],
      correlation_id: ev.correlation_id
    )

    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{
          source: :spawner,
          type: :"spawn.failed",
          payload: %{"cap_profile_name" => name} = p
        } = ev,
        state
      )
      when is_binary(name) do
    # spawn.failed (twin of pod.failed): admin.spawn.request dispatch DROPPED the spawn AFTER the API
    # already answered 202 (no pod was ever created — hence no pod_id). Subject = cap_profile_name (the
    # role): recurrence = "this role keeps failing to spawn" (issue_id is per-request → never recurs).
    # op="spawn", default :recurrence escalation. Was ORPHANED: produced, never consumed → the 202 lied silently.
    record(state, "spawn", name, p["reason"],
      reason_detail: p["reason_detail"],
      correlation_id: ev.correlation_id
    )

    {:noreply, state}
  end

  # ── Cat-5 (source :starfleet) — DIRECT escalation, no recurrence gate (max severity). ──
  # The 3 types are LITERAL matches (atoms pre-registered by starfleet/application.ex + events.yaml)
  # — no dynamic atom construction. Sig = "cat5:<source>:<subject>" (per-subject dedup lives in the
  # issue timeline, not a gate); correlation_id (wave E) links the issue to the causing mandate.
  def handle_info(
        %Fleet.Event{source: :starfleet, type: :"starfleet.audit_cat5_pod_drift"} = ev,
        state
      ) do
    escalate_cat5(state, "pod_drift", ev)
    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{source: :starfleet, type: :"starfleet.audit_cat5_workflow_map_failed"} = ev,
        state
      ) do
    escalate_cat5(state, "workflow_map_failed", ev)
    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{source: :starfleet, type: :"starfleet.audit_cat5_oauth_refresh_failed"} = ev,
        state
      ) do
    escalate_cat5(state, "oauth_refresh_failed", ev)
    {:noreply, state}
  end

  # Any other message (non-failure events we also see via the Bus, or non-Fleet.Event) → no-op.
  def handle_info(_other, state), do: {:noreply, state}

  # Routes the incident to the registry, offloaded via `:runner` (default sync). The 4-tuple
  # `(op, subject, reason, opts)` is the contract of `IncidentRegistry.record_or_escalate/4` (`op="pod"` →
  # `opts=[]`; `op="wake"` → `escalate_kind:/pane:`). The outcome is logged (never swallowed): an
  # unrecorded incident / a failed escalation must be VISIBLE (forge down? registry unavailable?).
  defp record(state, op, pod_id, reason, reg_opts) do
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

        {:escalation_failed, e} ->
          Logger.error(
            "IncidentConsumer: #{op}.failed #{pod_id} RECURRENT but escalation FAILED — NO sysadmin " <>
              "issue created (forge down ?) : #{inspect(e)}"
          )

        {:recorded_volatile, e} ->
          Logger.error(
            "IncidentConsumer: #{op}.failed #{pod_id} : incident en MÉMOIRE seule — write WAL ÉCHOUÉ " <>
              "(#{inspect(e)}) : PAS durable cross-session tant que la sync forge async n'a pas absorbé " <>
              "(BND-055 : un crash avant la sync perdrait la récurrence)"
          )

        {:record_failed, e} ->
          Logger.error(
            "IncidentConsumer: #{op}.failed #{pod_id} : incident NOT recorded (registry unavailable) : #{inspect(e)}"
          )

        {:escalation_suppressed, issue} ->
          # Récurrence sous cooldown : notée au registre (count/last_seen), l'issue existante
          # porte l'alarme — :debug (une panne durable récurre à CHAQUE tick, un warning par
          # tick noierait la trace que l'issue ouverte couvre déjà).
          Logger.debug(
            "IncidentConsumer: #{op}.failed #{pod_id} recurrent under cooldown — noted, " <>
              "existing issue #{inspect(issue)} carries the alarm"
          )

        other ->
          Logger.warning(
            "IncidentConsumer: #{op}.failed #{pod_id} → unexpected outcome #{inspect(other)}"
          )
      end
    end

    (state.runner || (&run_sync/1)).(exec)
  end

  defp run_sync(fun), do: fun.()

  # Cat-5 → issue forge durable dès la PREMIÈRE occurrence via `IncidentRegistry.escalate_gated/5`
  # (label `error_cat5`, triage sysadmin distinct des crashs pod) — pas de gate de récurrence
  # sur la 1re alarme (sévérité max, doctrine A-06) ; seules les RÉPÉTITIONS de la même
  # signature sous le cooldown du registre sont supprimées (l'issue ouverte porte l'alarme —
  # sans ça, un drift permanent re-créait une issue par event). Offloadée comme `record/5`
  # (touche la forge). L'échec d'escalade est LOUD : perdre l'alarme re-silencierait exactement
  # l'évaporation que ce rail vient de fermer (l'inversion sévérité/durabilité, acte4 A-06).
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
              "(forge down ?) : #{inspect(e)} — the max-severity alarm is NOT engraved"
          )
      end
    end

    (state.runner || (&run_sync/1)).(exec)
  end

  defp extract_cat5_reason(%{"reason" => reason}), do: reason
  defp extract_cat5_reason(payload), do: payload
end
