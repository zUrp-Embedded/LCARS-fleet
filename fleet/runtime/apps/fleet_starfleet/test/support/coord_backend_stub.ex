defmodule Fleet.Starfleet.CoordBackendStub do
  @moduledoc """
  Stub `CoordBackend` pour tests.

  Enregistre les invocations dans `Application.put_env(:fleet_starfleet,
  :coord_invocations, [...])` pour assertion side-effect.

  Reset via `Application.put_env(:fleet_starfleet, :coord_invocations, [])`.
  """

  @behaviour Fleet.Starfleet.CoordBackend

  @impl Fleet.Starfleet.CoordBackend
  def handle_decision(decision) do
    log({:decision, decision})
    :ok
  end

  @impl Fleet.Starfleet.CoordBackend
  def handle_escalation(source, payload) do
    log({:escalation, source, payload})
    :ok
  end

  # DN 9 C2.3 amendement — arités étendues correlation_id
  @impl Fleet.Starfleet.CoordBackend
  def handle_decision(decision, correlation_id) do
    log({:decision, decision, correlation_id})
    :ok
  end

  @impl Fleet.Starfleet.CoordBackend
  def handle_escalation(source, payload, correlation_id) do
    log({:escalation, source, payload, correlation_id})
    :ok
  end

  defp log(entry) do
    invocations = Application.get_env(:fleet_starfleet, :coord_invocations, [])
    Application.put_env(:fleet_starfleet, :coord_invocations, [entry | invocations])
  end
end
