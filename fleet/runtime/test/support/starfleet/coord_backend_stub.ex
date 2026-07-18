defmodule Fleet.Starfleet.CoordBackendStub do
  @moduledoc """
  `CoordBackend` stub for tests.

  Records invocations in `Application.put_env(:fleet_starfleet,
  :coord_invocations, [...])` for side-effect assertions.

  Reset via `Application.put_env(:fleet_starfleet, :coord_invocations, [])`.

  BL-021 (B) — the `/1` and `/2` compat shims are removed. Only the
  canonical arities are kept (DN 9 C2.3).
  """

  @behaviour Fleet.Starfleet.CoordBackend

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
