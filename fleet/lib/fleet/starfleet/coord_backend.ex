defmodule Fleet.Starfleet.CoordBackend do
  @moduledoc """
  Backend seam for validated decisions and Cat 5 escalations.

  The configured backend receives an explicit correlation ID. `NotWiredYet` is
  the side-effect-free default; audit ownership stays with each caller.
  """

  @callback handle_decision(
              decision :: Fleet.Decision.t(),
              correlation_id :: String.t() | nil
            ) :: :ok | {:error, term()}

  @callback handle_escalation(
              source :: atom(),
              payload :: map(),
              correlation_id :: String.t() | nil
            ) :: :ok | {:error, term()}

  @doc "Returns the configured coord backend or `NotWiredYet`."
  @spec resolved() :: module()
  def resolved do
    Application.get_env(:lcars_fleet, :starfleet_coord_backend, __MODULE__.NotWiredYet)
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
