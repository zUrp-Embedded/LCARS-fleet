defmodule Fleet.Starfleet.DriftMonitor do
  @moduledoc """
  GenServer pure subscriber `Fleet.EventRouter.Bus` topic `fleet.events`.

  Pas de state runtime (compteur drift maintenu chantier 9 PROMOTED
  `fleet_ipc_filter` ETS — DriftMonitor lit `drift_count` payload
  broadcast, pas de duplication compteur local).

  ## Events handlés

  | event_type | trigger Cat 5 |
  |---|---|
  | `pod_drift` | si `drift_count >= 3` |
  | `pipeline.failed` | inconditionnel |
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
  def handle_info({_atom, %{"event_type" => "pod_drift", "payload" => payload}}, state) do
    if drift_count(payload) >= @drift_threshold do
      Cat5Escalator.escalate(:pod_drift, payload)
    end

    {:noreply, state}
  end

  def handle_info(
        {_atom, %{"event_type" => "pipeline.failed", "payload" => payload}},
        state
      ) do
    Cat5Escalator.escalate(:pipeline_failed, payload)
    {:noreply, state}
  end

  def handle_info(
        {_atom, %{"event_type" => "oauth.refresh.failed", "payload" => payload}},
        state
      ) do
    Cat5Escalator.escalate(:oauth_refresh_failed, payload)
    {:noreply, state}
  end

  def handle_info(
        {_atom, %{"event_type" => "audit.verdict", "payload" => payload}},
        state
      ) do
    case Gatekeeper.validate(payload["decision_json"] || "") do
      {:ok, decision} ->
        _ = coord_backend().handle_decision(decision)

      {:error, reason} ->
        _ =
          AuditLog.write(%{
            "source" => "invalid_decision",
            "reason" => reason,
            "raw" => payload
          })

        Logger.warning("starfleet drift_monitor: invalid audit.verdict — #{reason}")
    end

    {:noreply, state}
  end

  def handle_info({_atom, %{"event_type" => _other}}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

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
