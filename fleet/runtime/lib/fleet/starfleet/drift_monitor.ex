defmodule Fleet.Starfleet.DriftMonitor do
  @moduledoc """
  Pure-subscriber GenServer on `Fleet.EventRouter.Bus` topic `fleet.events`.

  No runtime state: thresholds are evaluated against counters carried by the payload
  itself, per the DECLARATIVE routing table (`events.yaml` → `Bus.event_routing/0`) —
  never a local counter, never a number hardcoded here.

  Producer status (Q2 draft wiring — "at least it blinks"):
  - `workflow_map.failed` — LIVE via a DRAFT producer: `Pilot.StepRunConsumer` emits it (source
    `:workflow`) on a `:workflow_map_load_failed` in the forge-driven rail. Honest but partial (covers
    the main dispatch load-failure, not yet every rail path). Routes to `Cat5Escalator`.
  - `audit.verdict` — LIVE via a DRAFT producer: `Pilot.StepRunConsumer.apply_verdict` emits it (source
    `:workflow`) on an escalation-worthy judge verdict (halt/`halt_invalid` → freeze-to-arch), translated
    to a decision-v1 `{decision: "escalate", reason: "audit_verdict", details: <real verdict>}`. Routed
    DIRECTLY to `CoordBackend` (`handle_decision`), NOT via `Cat5Escalator`.
  - `pod.drift` — DORMANT: the handler is wired + tested but NO
    producer emits it. The claimed `Fleet.Spawner.PermanentBoot` producer does not exist,
    and the "corrupt versioned base seed" it targeted disappeared with the boot-from-base nuke
    (unified seed flow). If a real drift signal is ever needed, whoever wires it MUST add its
    `source:` in the ROUTING TABLE (anti-spoof rule — the table key is the {source, type} pair).
  - `oauth.refresh.failed` — DORMANT: no producer on the launcher/credentials side yet.

  All handlers stay ready — the dormant ones route as soon as a real producer emits.

  ## Events handled

  | event_type | source match | Cat 5 trigger |
  |---|---|---|
  | `pod.drift` | `:spawner` (dormant — no producer) | per table threshold (drift_count) |
  | `workflow_map.failed` | `:workflow` (draft producer) | unconditional → `Cat5Escalator` |
  | `oauth.refresh.failed` | `:credentials` (dormant) | unconditional |
  | `audit.verdict` | `:workflow` (draft producer) | validate decision JSON → `CoordBackend` |

  ## Why a runtime process

  GenServer = subscribe to asynchronous cross-process PubSub events. Pure
  functions are impossible. No state = minimal Iron Law (1 process, no local
  ETS).
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.{AuditLog, Cat5Escalator, CoordBackend, Gatekeeper}

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
  # TABLE-DRIVEN subscriber (audit B-05): the event+source → classification/action/threshold/sink
  # table is DATA (`events.yaml` routing, loaded by Catalog into `Bus.event_routing/0`), this module
  # is the MECHANIC that applies it. Adding an incident class, changing a threshold or a sink is a
  # registry edit, not a new handler clause. The anti-spoof rule is structural: the table is keyed
  # on the `{source, type}` PAIR, so a spoofed-source event of a routed type misses the lookup and
  # is ignored — the rule can no longer be forgotten one clause at a time. Dormant routes (pod.drift,
  # oauth.refresh.failed — no producer) stay one emit away from live, and are NOT coverage.
  def handle_info(
        %Fleet.Event{source: source, type: type, payload: payload, correlation_id: cid},
        state
      ) do
    case Map.get(Fleet.EventRouter.Bus.event_routing(), {source, type}) do
      %{action: :cat5, cat5_source: tag, threshold: threshold} ->
        if meets_threshold?(payload, threshold), do: Cat5Escalator.escalate(tag, payload, cid)

      %{action: :coord_decision} ->
        dispatch_audit_verdict(payload, cid)

      # Unrouted, or an action owned by ANOTHER mechanic (`incident`/`incident_cat5` →
      # IncidentConsumer): not ours, ignore.
      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Threshold gate from the TABLE (nil = act on every occurrence): act only when the payload's
  # declared counter reaches the declared min — the number lives in the registry, not here.
  defp meets_threshold?(_payload, nil), do: true

  defp meets_threshold?(payload, %{counter: counter, min: min}),
    do: counter_value(payload, counter) >= min

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

  # The declared counter read from the payload — non-integer/absent = 0 (below any min >= 1:
  # a malformed counter never triggers a Cat-5).
  defp counter_value(payload, counter) do
    case Map.get(payload, counter) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end
end
