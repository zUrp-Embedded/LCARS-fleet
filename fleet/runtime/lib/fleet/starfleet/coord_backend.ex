defmodule Fleet.Starfleet.CoordBackend do
  @moduledoc """
  Behaviour seam over `Fleet.Coord`.

  Default `NotWiredYet` (test/fallback, returns `:ok` — Cat 5 escalation is
  audit-only, no runtime side effect); prod wires `Fleet.Coord` via `runtime.exs`
  (`:fleet_starfleet, :coord_backend`). Consistent with the deny-by-default +
  fail-safe stance (the audit log is written regardless of the backend).

  The `/1` and `/2` compat shims were removed — only the canonical arities with
  an explicit correlation_id are kept.

  ## Callbacks

    * `handle_decision/2` — consume a validated decision (gatekeeper output) +
      explicit correlation_id
    * `handle_escalation/3` — consume a Cat 5 escalation (source + payload) +
      explicit correlation_id
  """

  @callback handle_decision(
              decision :: Fleet.Starfleet.Decision.t(),
              correlation_id :: String.t() | nil
            ) :: :ok | {:error, term()}

  @callback handle_escalation(
              source :: atom(),
              payload :: map(),
              correlation_id :: String.t() | nil
            ) :: :ok | {:error, term()}

  @doc """
  The wired coord escalation backend (config `:fleet_starfleet, :coord_backend`),
  or `NotWiredYet` by default (coord not wired). SINGLE SOURCE of
  this lookup for the escalation producers (`Cat5Escalator`, `DriftMonitor`) — a
  single default to keep aligned.
  """
  @spec resolved() :: module()
  def resolved do
    Application.get_env(:fleet_starfleet, :coord_backend, __MODULE__.NotWiredYet)
  end
end

defmodule Fleet.Starfleet.CoordBackend.NotWiredYet do
  @moduledoc false

  @behaviour Fleet.Starfleet.CoordBackend

  require Logger

  @impl Fleet.Starfleet.CoordBackend
  def handle_decision(_decision, _correlation_id) do
    Logger.debug("CoordBackend: handle_decision/2 deferred (not wired)")
    :ok
  end

  @impl Fleet.Starfleet.CoordBackend
  def handle_escalation(source, _payload, _correlation_id) do
    Logger.debug("CoordBackend: handle_escalation/3 #{inspect(source)} deferred (not wired)")

    :ok
  end
end
