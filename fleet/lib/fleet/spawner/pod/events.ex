defmodule Fleet.Spawner.Pod.Events do
  @moduledoc """
  Broadcasts pod lifecycle events in the canonical `%Fleet.Event{source: :spawner}` envelope.

  `lossy_broadcast/2` carries observability events through `Fleet.EventRouter.Bus.safe_emit/4` and
  always returns `:ok`. `required_broadcast/2` carries `pod.completed`; it returns a broadcast error
  so the pod remains in extraction and can retry instead of releasing an orphaned completion.

  The `:fleet_spawner, :event_bus` seam applies only to the required path. Both paths correlate the
  lifecycle event with the issue identifier in the payload.
  """

  require Logger

  alias Fleet.EventRouter.Bus

  @doc """
  Emits an observability event through the lossy bus policy and always returns `:ok`.

  Conversion of the binary event type and emission failures are contained by `Bus.safe_emit/4`.
  """
  @spec lossy_broadcast(String.t(), map()) :: :ok
  def lossy_broadcast(event_type, payload) when is_binary(event_type) do
    _ =
      Bus.safe_emit(
        :spawner,
        event_type,
        [
          pod_id: Map.get(payload, "pod_id"),
          correlation_id: Map.get(payload, "issue_id"),
          payload: payload
        ],
        context: "Pod lossy_broadcast #{event_type} (non-fatal)"
      )

    :ok
  end

  @doc """
  Emits a load-bearing lifecycle event without flattening failures.

  Returns `:ok` or `{:error, {:broadcast_failed, reason}}`; raised bus failures use the same error
  shape.
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

  defp event_bus, do: Application.get_env(:fleet_spawner, :event_bus, Bus)

  defp build_spawner_event(event_type, payload) do
    Fleet.Event.new(:spawner, String.to_existing_atom(event_type),
      pod_id: Map.get(payload, "pod_id"),
      correlation_id: Map.get(payload, "issue_id"),
      payload: payload
    )
  end
end
