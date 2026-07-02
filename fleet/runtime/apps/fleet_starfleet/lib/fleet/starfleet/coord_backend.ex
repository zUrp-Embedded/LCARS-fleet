defmodule Fleet.Starfleet.CoordBackend do
  @moduledoc """
  Behaviour wrap autour de `Fleet.Coord` (chantier 14).

  Permet de différer la dep `fleet_coord` jusqu'au câblage chantier 14.
  Default `NotWiredYet` retourne `:ok` (escalade Cat 5 audit-only,
  pas de side effect runtime). Cohérent canon §0 #1 refus par défaut +
  fail-safe (audit log écrit même si coord pas câblé).

  BL-021 chantier 9 (B) — compat shims `/1` et `/2` retirés. Seules les
  arités canon avec correlation_id explicite (DN 9 C2.3) sont conservées.

  ## Callbacks

    * `handle_decision/2` — consume validated decision (gatekeeper output) +
      correlation_id explicite
    * `handle_escalation/3` — consume Cat 5 escalade (source + payload) +
      correlation_id explicite
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
  Backend d'escalade coord câblé (config `:fleet_starfleet, :coord_backend`), ou
  `NotWiredYet` par défaut (ch14 non câblé). SOURCE UNIQUE de cette lecture pour
  les producteurs d'escalade (`Cat5Escalator`, `DriftMonitor`) — un seul défaut à
  garder aligné.
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
    Logger.debug("starfleet coord_backend: handle_decision/2 deferred ch14 (not wired)")
    :ok
  end

  @impl Fleet.Starfleet.CoordBackend
  def handle_escalation(source, _payload, _correlation_id) do
    Logger.debug(
      "starfleet coord_backend: handle_escalation/3 #{inspect(source)} deferred ch14 (not wired)"
    )

    :ok
  end
end
