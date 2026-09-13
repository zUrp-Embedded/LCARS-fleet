defmodule Fleet.Project.Incidents do
  @moduledoc """
  Publishes project fallback events through EventRouter instead of calling the
  Pilot incident registry across the domain boundary. The incident consumer and
  events.yaml routes own conversion to durable incident records.

  Bus.safe_emit is lossy: returning :ok here does not establish delivery, persistence
  or ticket creation. The caller's fallback does not depend on that trace.
  """

  require Logger

  alias Fleet.EventRouter.Bus

  # op → event type: the two ops are the registry's dedup namespaces (`card:`/`declaration:`
  # signatures).
  @events %{"card" => :"project.card_failed", "declaration" => :"project.declaration_invalid"}

  @doc """
  Emits the card/declaration event and returns :ok without awaiting its consumer.
  Unknown operations log and return :ok without emitting. This is the incident_fun
  callback used by project fallback callers; reason must support to_string/1.
  """
  @spec emit(String.t(), String.t(), atom(), keyword()) :: :ok
  def emit(op, subject, reason, opts \\ [])

  def emit(op, subject, reason, opts) when is_map_key(@events, op) do
    _ =
      Bus.safe_emit(
        :project,
        Map.fetch!(@events, op),
        [
          correlation_id: subject,
          payload: %{
            "repo" => subject,
            "reason" => to_string(reason),
            "reason_detail" => Keyword.get(opts, :reason_detail),
            "producer" => "project.incidents"
          }
        ],
        on_unregistered: :log
      )

    :ok
  end

  def emit(op, subject, reason, _opts) do
    # A third op is a NEW incident class: it needs its route in `events.yaml` and its
    # `kind_describe` clause — refusing here keeps the table closed instead of emitting an event
    # nobody routes.
    Logger.error(
      "Project.Incidents: unknown incident op #{inspect(op)} (#{inspect(reason)} on " <>
        "#{subject}) — NOT emitted. Known ops: #{inspect(Map.keys(@events))}; a new class " <>
        "needs its events.yaml route, not a silent passthrough."
    )

    :ok
  end
end
