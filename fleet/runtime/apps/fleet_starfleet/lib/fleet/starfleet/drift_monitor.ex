defmodule Fleet.Starfleet.DriftMonitor do
  @moduledoc """
  Pure-subscriber GenServer on `Fleet.EventRouter.Bus` topic `fleet.events`.

  No runtime state: the threshold is evaluated against the `drift_count` carried
  by the `pod.drift` payload itself (`drift_count/1`), not by a local counter.

  ⚠ `pod.drift` is an event with NO current producer: the intended emitter
  (a pod-side IPC filter that would count the strikes) was never implemented.
  The `pod.drift` handler below is therefore wired but dormant as long as no
  producer emits the event. The other 3 handlers have real producers.

  ## Events handled

  | event_type | Cat 5 trigger |
  |---|---|
  | `pod.drift` | if `drift_count >= 3` (dormant: 0 producer) |
  | `workflow_map.failed` | unconditional |
  | `oauth.refresh.failed` | unconditional |
  | `audit.verdict` | validate the decision JSON then dispatch to CoordBackend |

  ## Why a runtime process

  GenServer = subscribe to asynchronous cross-process PubSub events. Pure
  functions are impossible. No state = minimal Iron Law (1 process, no local
  ETS).
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.{AuditLog, Cat5Escalator, CoordBackend, Gatekeeper}

  @drift_threshold 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # Canonical consumer form (2026-07-04 conformance, aligned with IncidentConsumer): `name: nil` =
    # anonymous (isolated tests, several instances); default is the named singleton (prod).
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    # `subscribe: false` seam (tests: events are sent directly to the process, no shared real Bus
    # that would pollute the async suite). Default true (prod).
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()
    {:ok, nil}
  end

  @impl GenServer
  # Pattern-match on the strict canonical %Fleet.Event{} schema. The legacy tuple
  # format was removed (producers migrated to the canonical schema).

  def handle_info(
        %Fleet.Event{type: :"pod.drift", payload: payload, correlation_id: cid},
        state
      ) do
    if drift_count(payload) >= @drift_threshold do
      Cat5Escalator.escalate(:pod_drift, payload, cid)
    end

    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{type: :"workflow_map.failed", payload: payload, correlation_id: cid},
        state
      ) do
    Cat5Escalator.escalate(:workflow_map_failed, payload, cid)
    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{type: :"oauth.refresh.failed", payload: payload, correlation_id: cid},
        state
      ) do
    Cat5Escalator.escalate(:oauth_refresh_failed, payload, cid)
    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{type: :"audit.verdict", payload: payload, correlation_id: cid},
        state
      ) do
    dispatch_audit_verdict(payload, cid)
    {:noreply, state}
  end

  # Ignore other unhandled %Fleet.Event{} types + any other message.
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp dispatch_audit_verdict(payload, correlation_id) do
    case Gatekeeper.validate(payload["decision_json"] || "") do
      {:ok, decision} ->
        # A {:error, {:no_policy_match, _}} used to be DROPPED here with no trace (DrDree finding,
        # 2026-07-05): a verdict with no policy vanished. Logged at WARNING — the structural fix
        # (a TOTAL routing table where a miss crashes at load) is a separate coord work-item.
        case CoordBackend.resolved().handle_decision(decision, correlation_id) do
          :ok -> :ok
          {:error, why} -> Logger.warning("DriftMonitor: verdict NON routé (#{inspect(why)})")
        end

      {:error, reason} ->
        # `reason` is a structured tuple ({:decision_invalid, cause}): `inspect` makes it
        # human-readable AND JSON-encodable (AuditLog encodes to NDJSON via Jason — a raw tuple
        # would raise Jason.EncodeError and a `#{reason}` interpolation would raise Protocol.UndefinedError).
        _ =
          AuditLog.write(%{
            "source" => "invalid_decision",
            "reason" => inspect(reason),
            "raw" => payload,
            "correlation_id" => correlation_id
          })

        Logger.warning("DriftMonitor: invalid audit.verdict — #{inspect(reason)}")
    end
  end

  defp drift_count(payload) do
    case Map.get(payload, "drift_count") do
      n when is_integer(n) -> n
      _ -> 0
    end
  end
end
