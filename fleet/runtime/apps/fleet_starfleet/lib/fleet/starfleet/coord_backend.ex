defmodule Fleet.Starfleet.CoordBackend do
  @moduledoc """
  Behaviour wrap autour de `Fleet.Coord` (chantier 14).

  Permet de différer la dep `fleet_coord` jusqu'au câblage chantier 14.
  Default `NotWiredYet` retourne `:ok` (escalade Cat 5 audit-only,
  pas de side effect runtime). Cohérent canon §0 #1 refus par défaut +
  fail-safe (audit log écrit même si coord pas câblé).

  ## Callbacks

    * `handle_decision/1` — consume validated decision (gatekeeper output)
    * `handle_escalation/2` — consume Cat 5 escalade (source + payload)
  """

  @callback handle_decision(decision :: Fleet.Starfleet.Decision.t()) ::
              :ok | {:error, term()}

  @callback handle_escalation(source :: atom(), payload :: map()) ::
              :ok | {:error, term()}
end

defmodule Fleet.Starfleet.CoordBackend.NotWiredYet do
  @moduledoc false

  @behaviour Fleet.Starfleet.CoordBackend

  require Logger

  @impl Fleet.Starfleet.CoordBackend
  def handle_decision(_decision) do
    Logger.debug("starfleet coord_backend: handle_decision deferred ch14 (not wired)")
    :ok
  end

  @impl Fleet.Starfleet.CoordBackend
  def handle_escalation(source, _payload) do
    Logger.debug(
      "starfleet coord_backend: handle_escalation #{inspect(source)} deferred ch14 (not wired)"
    )

    :ok
  end
end
