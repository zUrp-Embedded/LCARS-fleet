defmodule Fleet.Spawner.Pod.Events do
  @moduledoc """
  BUS broadcasts of the pod lifecycle — cluster extracted from `Fleet.Spawner.Pod`.

  A single role: broadcast a pod's lifecycle events on the `fleet.events` bus, under the strict
  canonical envelope `%Fleet.Event{source: :spawner}`. The load-bearing vs LOSSY separation
  (cf. the section comment below) is the heart of the module: a `pod.completed` swallowed silently
  would wedge the step_run (forge lock held for life), a swallowed `pod.failed`/`wake.failed` is
  only a loss of observability.

  No state, no Port, no timer: the `Pod` passes `event_type` (binary) + `payload` (map) as
  arguments; the module builds the envelope and broadcasts it.

  ## Contract (called by `Pod`)

  - `lossy_broadcast/2` (PUBLIC) — OBSERVABILITY/escalation (`pod.failed`, `wake.failed`).
    A failure is non-blocking; always returns `:ok`. Emits via the protected core
    `Fleet.EventRouter.Bus.safe_emit/4` (the UNIFIED lossy-emit policy, Ring 0: failure logged,
    never a crash of the pod).
  - `required_broadcast/2` (PUBLIC) — load-bearing LIFECYCLE (`pod.completed`). The failure is NOT
    swallowed: returns `:ok` | `{:error, {:broadcast_failed, _}}`. The `:extracting` state
    (`do_extract_proceed`) does NOT release/kill the pod on an orphaned completion. DELIBERATELY
    outside `Bus.safe_emit` (cf. its comment — safe_emit flattens every failure into `:ok`,
    indistinguishable from a success).

  The app-env SEAM (`:fleet_spawner, :event_bus`, default `Fleet.EventRouter.Bus`) carries ONLY the
  load-bearing path `required_broadcast/2`: it serves to inject a DETERMINISTIC failure on
  `pod.completed` in test (a stub that raises / returns `{:error,_}`) without touching the global
  registry — injecting a failure on a lossy broadcast has no observable (the failure is
  swallowed there by contract). `event_bus/0` and `build_spawner_event/2` are internal (called ONLY
  by `required_broadcast/2`).
  """

  require Logger

  alias Fleet.EventRouter.Bus

  # Load-bearing vs lossy classification of the broadcast (cf. task_queue/server.ex, same move).
  # A single `safe_broadcast` that would swallow EVERY exception into `:ok` would also engulf `pod.completed`
  # which the StepRunConsumer DEPENDS on to finish the step_run: a swallowed `pod.completed` = the pod "succeeds" (release/
  # kill for a one-shot) BUT the end-of-step-run never fires → forge lock held for life (silent
  # wedge). Hence the SEPARATION:
  #   - `lossy_broadcast/2`: OBSERVABILITY/escalation (`pod.failed`, `wake.failed`). A failure is
  #     non-blocking (logged by `Bus.safe_emit/4`, the shared lossy-emit core) — a fleet_pilot consumer
  #     records them into the read-model (a lost event = a missing record; the loss is logged at emit),
  #     nobody FINISHES a step_run on them.
  #   - `required_broadcast/2`: load-bearing LIFECYCLE (`pod.completed`). The failure is NOT swallowed: it
  #     bubbles up `{:error, {:broadcast_failed, _}}` → the `:extracting` state does NOT release/kill the pod on an
  #     orphaned completion; it stays alive (a bounded :extract_retry timer re-fires the extract), fail-loud. Both go
  #     through the strict canonical envelope `%Fleet.Event{source: :spawner}`.

  @doc """
  OBSERVABILITY/escalation broadcast (`pod.failed`, `wake.failed`): emission via the protected core
  `Bus.safe_emit/4` (the lossy-emit policy has ONE authority, Ring 0). An event_router crash
  (malformed event, unknown type name) NEVER crashes the pod process (gen_statem):
  safe_emit logs and neutralizes. The BINARY `event_type` is passed as-is — the anti atom-leak
  conversion (`to_existing_atom`) lives UNDER safe_emit's rescue. `:on_unregistered` default
  (`:log`): the loss of an observability event stays visible in the log. Always returns `:ok`
  (fire-and-forget contract — the `{:error,_}` PubSub passthrough is discarded: nobody FINISHES a
  step_run on these events).
  """
  @spec lossy_broadcast(String.t(), map()) :: :ok
  def lossy_broadcast(event_type, payload) when is_binary(event_type) do
    _ =
      Bus.safe_emit(
        :spawner,
        event_type,
        [
          pod_id: Map.get(payload, "pod_id"),
          # Traceability: correlate the pod-lifecycle event to the ISSUE it serves (the end-to-end key
          # spawn→work→complete→review→merge). Without it every pod.failed/wake.failed went `nil` and no
          # incident was tie-able to the mandate that caused it (acte3 vague E).
          correlation_id: Map.get(payload, "issue_id"),
          payload: payload
        ],
        context: "Pod lossy_broadcast #{event_type} (non-fatal)"
      )

    :ok
  end

  @doc """
  load-bearing LIFECYCLE broadcast (`pod.completed`): the failure is NOT swallowed. DELIBERATELY
  outside the `Bus.safe_emit/4` core: safe_emit flattens every failure into a logged `:ok` (its
  contract: "never crash the emitter", the loss stays visible in the log only) — indistinguishable from a success for the caller,
  whereas here the `:extracting` state MUST distinguish in order to retain the pod. Returns `:ok` or
  `{:error, {:broadcast_failed, reason}}` (raise OR `{:error, _}` from Bus.broadcast). Logged ERROR:
  a `pod.completed` not broadcast = potential wedge (the step_run does not finish, lock held).
  """
  @spec required_broadcast(String.t(), map()) :: :ok | {:error, {:broadcast_failed, term()}}
  def required_broadcast(event_type, payload) when is_binary(event_type) do
    case event_bus().broadcast(Bus.main_topic(), build_spawner_event(event_type, payload)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "pod #{Map.get(payload, "pod_id")} required_broadcast #{event_type} FAILED: " <>
            "#{inspect(reason)} — lifecycle NOT broadcast (the step_run will not finish; pod not released/killed, fail-loud)"
        )

        {:error, {:broadcast_failed, reason}}
    end
  rescue
    e ->
      Logger.error(
        "pod #{Map.get(payload, "pod_id")} required_broadcast #{event_type} RAISED: " <>
          "#{Exception.message(e)} — lifecycle NOT broadcast (pod not released/killed, fail-loud)"
      )

      {:error, {:broadcast_failed, e}}
  end

  # Bus seam (default = the real `Fleet.EventRouter.Bus`). App-env override (same pattern as the
  # other pod seams: claude_dir, state_fs_root…) → a test injects a stub bus that returns `{:error,_}` / raises
  # on `pod.completed`, without touching the global registry. Carries ONLY the load-bearing path
  # `required_broadcast/2`: the lossy path goes through `Bus.safe_emit/4` directly (a failure stub has
  # no observable there, the failure is swallowed by contract).
  defp event_bus, do: Application.get_env(:fleet_spawner, :event_bus, Bus)

  # Builds the canonical envelope %Fleet.Event{source: :spawner} for the load-bearing path
  # (`required_broadcast/2` — the lossy path builds its own via `Bus.safe_emit/4`/`Fleet.Event.new`).
  defp build_spawner_event(event_type, payload) do
    Fleet.Event.new(:spawner, String.to_existing_atom(event_type),
      pod_id: Map.get(payload, "pod_id"),
      # Traceability: correlate to the ISSUE the pod serves (end-to-end key) — cf. lossy_broadcast.
      correlation_id: Map.get(payload, "issue_id"),
      payload: payload
    )
  end
end
