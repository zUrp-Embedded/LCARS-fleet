defmodule Fleet.Project.Incidents do
  @moduledoc """
  Producer of the project incident EVENTS — downward, on the bus, never through an upward seam
  (BL-6-114).

  Calling `Fleet.Pilot.IncidentRegistry` from here through an app-env seam would pass the module
  across the boundary AS A VALUE, in the direction the stratification exists to forbid (`work` →
  `steering`), where boundary cannot see it. And the registry is a COUNTER-AND-TICKET desk, nothing
  of the piloting layer: such a dependency buys NO SEMANTICS, only a private door.

  So this module PUBLISHES on the bus (`Fleet.EventRouter`, a declared dep, downward), and the
  conversion to a durable incident happens where it belongs — the `incident` routes of
  `events.yaml` (`gate: immediate`), consumed by `Pilot.IncidentConsumer`, which subscribes on its
  own floor. One destination (registry → `error_system` issue in admiral's inbox), one path.

  ## What a lost event means here, and what it does NOT mean

  The caller's own behaviour is unchanged — a card that will not load already falls back to the
  delegation default and says so in a warning; the event is the DURABLE half, the one a human
  reads later. `Bus.safe_emit` is lossy by contract (a missing subscriber never crashes the
  producer): a fallback that runs is never made worse by its trace failing to land.
  """

  require Logger

  alias Fleet.EventRouter.Bus

  # op → event type: the two ops are the registry's dedup namespaces (`card:`/`declaration:`
  # signatures).
  @events %{"card" => :"project.card_failed", "declaration" => :"project.declaration_invalid"}

  @doc """
  Publishes the incident event for a card/declaration fallback, or says loudly that nothing left.

  Contract of the `:incident_fun` seam at both call sites: `(op, subject, reason, opts)`, always
  `:ok` — fire-and-forget, the fallback never depends on its trace.
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
