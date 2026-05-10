defmodule Fleet.IpcFilter.EventBackend do
  @moduledoc """
  Behaviour wrap autour de la diffusion events `:refuse_pattern_match`
  + `:pod_drift` vers le bus PubSub fleet_event_router (chantier 11).

  Permet de différer la dep `:phoenix_pubsub` jusqu'au câblage chantier
  11 — cohérent pattern Backend ch3/ch6/ch8 PROMOTED.
  """

  @callback broadcast(event :: atom(), payload :: map()) :: :ok | {:error, term()}
end

defmodule Fleet.IpcFilter.EventBackend.NotWiredYet do
  @moduledoc """
  Backend placeholder. Le wiring `Phoenix.PubSub.broadcast(Fleet.PubSub,
  "fleet.events", {event, payload})` se fait post chantier 11
  `fleet_event_router`.

  Retourne `:ok` (pas d'effet de bord) — `fleet_ipc_filter` doit
  rester fonctionnel sans bus events câblé (filter decision allow/deny
  reste correcte, juste pas d'event broadcast cross-pod).
  """

  @behaviour Fleet.IpcFilter.EventBackend

  @impl Fleet.IpcFilter.EventBackend
  def broadcast(_event, _payload), do: :ok
end
