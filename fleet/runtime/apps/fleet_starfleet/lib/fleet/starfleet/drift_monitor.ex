defmodule Fleet.Starfleet.DriftMonitor do
  @moduledoc """
  GenServer pure subscriber `Fleet.EventRouter.Bus` topic `fleet.events`.

  Pas de state runtime : le seuil est évalué sur le `drift_count` porté par le
  payload `pod.drift` lui-même (`drift_count/1`), pas par un compteur local.

  ⚠ `pod.drift` est un event SANS producteur courant : l'émetteur prévu
  (un filtre IPC pod-side qui compterait les strikes) n'a jamais été implémenté.
  Le handler `pod.drift` ci-dessous est donc câblé mais dormant tant qu'aucun
  producteur n'émet l'event. Les 3 autres handlers ont des producteurs réels.

  ## Events handlés

  | event_type | trigger Cat 5 |
  |---|---|
  | `pod.drift` | si `drift_count >= 3` (dormant : 0 producteur) |
  | `workflow_map.failed` | inconditionnel |
  | `oauth.refresh.failed` | inconditionnel |
  | `audit.verdict` | validate JSON décision puis dispatch CoordBackend |

  ## Process raison runtime

  GenServer = subscribe PubSub events asynchrones cross-process
  (ch11 Phoenix.PubSub). Pure functions impossibles. Pas de state =
  Iron Law minimal (1 process, pas d'ETS local).
  """

  use GenServer

  require Logger

  alias Fleet.EventRouter.Bus
  alias Fleet.Starfleet.{AuditLog, Cat5Escalator, Gatekeeper}

  @drift_threshold 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    Bus.subscribe()
    {:ok, nil}
  end

  @impl GenServer
  # DN 13 C2.3-starfleet — pattern match schema canon %Fleet.Event{} strict
  # (DN 11 C3.1+C3.2). Legacy tuple format retiré chantier 3 BL-021 (les
  # producteurs sont passés au schema canon).

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

  # Ignore les autres types de %Fleet.Event{} non handlés + tout autre message.
  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp dispatch_audit_verdict(payload, correlation_id) do
    case Gatekeeper.validate(payload["decision_json"] || "") do
      {:ok, decision} ->
        _ = coord_backend().handle_decision(decision, correlation_id)

      {:error, reason} ->
        _ =
          AuditLog.write(%{
            "source" => "invalid_decision",
            "reason" => reason,
            "raw" => payload,
            "correlation_id" => correlation_id
          })

        Logger.warning("starfleet drift_monitor: invalid audit.verdict — #{reason}")
    end
  end

  defp drift_count(payload) do
    case Map.get(payload, "drift_count") do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp coord_backend do
    Application.get_env(
      :fleet_starfleet,
      :coord_backend,
      Fleet.Starfleet.CoordBackend.NotWiredYet
    )
  end
end
