defmodule Fleet.Starfleet.DriftMonitor do
  @moduledoc """
  Pure-subscriber GenServer on `Fleet.EventRouter.Bus` topic `fleet.events`.

  No runtime state: the threshold is evaluated against the `drift_count` carried
  by the `pod.drift` payload itself (`drift_count/1`), not by a local counter.

  Producer status (Q2 draft wiring — "at least it blinks"):
  - `workflow_map.failed` — LIVE via a DRAFT producer: `Pilot.StepRunConsumer` emits it (source
    `:workflow`) on a `:workflow_map_load_failed` in the forge-driven rail. Honest but partial (covers
    the main dispatch load-failure, not yet every rail path). Routes to `Cat5Escalator`.
  - `audit.verdict` — LIVE via a DRAFT producer: `Pilot.StepRunConsumer.apply_verdict` emits it (source
    `:workflow`) on an escalation-worthy judge verdict (halt/`halt_invalid` → freeze-to-arch), translated
    to a decision-v1 `{decision: "escalate", reason: "audit_verdict", details: <real verdict>}`. Routed
    DIRECTLY to `CoordBackend` (`handle_decision`), NOT via `Cat5Escalator`.
  - `pod.drift` — LIVE via `Fleet.Spawner.PermanentBoot` (source `:spawner`): emitted when a
    permanent pod's base SEED is CORRUPT (present but no valid session UUID), with `drift_count` at the
    threshold → escalate on the FIRST occurrence (a corrupt versioned seed is a certain problem, not a
    strike to accumulate). Routes to `Cat5Escalator`. (The originally-intended pod-side IPC strike filter
    is still unbuilt — this is a distinct, honest producer.)
  - `oauth.refresh.failed` — STILL DORMANT: no producer on the launcher/credentials side yet.

  All handlers stay ready — the dormant two route as soon as a real producer emits.

  ## Events handled

  | event_type | source match | Cat 5 trigger |
  |---|---|---|
  | `pod.drift` | `:spawner` | if `drift_count >= 3` |
  | `workflow_map.failed` | `:workflow` (draft producer) | unconditional → `Cat5Escalator` |
  | `oauth.refresh.failed` | type-only (dormant) | unconditional |
  | `audit.verdict` | `:workflow` (draft producer) | validate decision JSON → `CoordBackend` |

  ## Why a runtime process

  GenServer = subscribe to asynchronous cross-process PubSub events. Pure
  functions are impossible. No state = minimal Iron Law (1 process, no local
  ETS).

  **Last revised**: 2026-07-18
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.{AuditLog, Cat5Escalator, CoordBackend, Gatekeeper}

  @drift_threshold 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    # Canonical consumer form (aligned with IncidentConsumer): `name: nil` =
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
  # Pattern-match on the strict canonical %Fleet.Event{} schema.
  #
  # Q2 anti-spoof: the WIRED types match their producer's source — `workflow_map.failed` +
  # `audit.verdict` on `:workflow` (`Pilot.StepRunConsumer`), and `pod.drift` on `:spawner`
  # (`Spawner.PermanentBoot`, F-C043). Matching the source means a SPOOFED-source event of that type (e.g. a
  # pod broadcasting `audit.verdict` on `:event_router`, or `pod.drift` on `:pod`) CANNOT trigger the Cat 5
  # escalation. The remaining DORMANT type (`oauth.refresh.failed`) stays TYPE-ONLY: no producer exists yet,
  # so there is no legit source to match — whoever wires it MUST add its `source:` (same anti-spoof rule).

  # F-C043 — `pod.drift` has a REAL producer: `Fleet.Spawner.PermanentBoot` emits it (source
  # `:spawner`) when a permanent pod's base seed is CORRUPT, with `drift_count` at the threshold (a corrupt
  # versioned seed is a CERTAIN problem → escalate on first occurrence). Per the anti-spoof rule, we
  # match `source: :spawner` — a spoofed `pod.drift` on another source CANNOT trigger the Cat 5.
  def handle_info(
        %Fleet.Event{source: :spawner, type: :"pod.drift", payload: payload, correlation_id: cid},
        state
      ) do
    if drift_count(payload) >= @drift_threshold do
      Cat5Escalator.escalate(:pod_drift, payload, cid)
    end

    {:noreply, state}
  end

  def handle_info(
        %Fleet.Event{
          source: :workflow,
          type: :"workflow_map.failed",
          payload: payload,
          correlation_id: cid
        },
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
        %Fleet.Event{
          source: :workflow,
          type: :"audit.verdict",
          payload: payload,
          correlation_id: cid
        },
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
        # A {:error, {:no_policy_match, _}} dropped here with no trace would make a verdict with
        # no policy vanish → logged at WARNING. The structural fix
        # (a TOTAL routing table where a miss crashes at load) is a separate coord work-item.
        case CoordBackend.resolved().handle_decision(decision, correlation_id) do
          :ok -> :ok
          {:error, why} -> Logger.warning("DriftMonitor: verdict NOT routed (#{inspect(why)})")
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
