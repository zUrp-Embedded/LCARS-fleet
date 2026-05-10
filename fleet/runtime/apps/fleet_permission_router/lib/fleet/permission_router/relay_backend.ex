defmodule Fleet.PermissionRouter.RelayBackend do
  @moduledoc """
  Behaviour wrap autour de la diffusion `:permission_relay_request` +
  réception `:permission_relay_response` (step 4 du flow can_use_tool).

  Permet de différer la dep `:phoenix_pubsub` jusqu'au câblage chantier
  11 `fleet_event_router` — cohérent pattern Backend ch3/ch6/ch7/ch8/ch9
  PROMOTED.

  ## Sémantique

    * `relay_request/2` — diffuse `:permission_relay_request` payload
      avec `ref` unique. Le caller `receive` ensuite la réponse
      matching ref via le mailbox du process appelant. Pas blocant
      côté backend (broadcast fire-and-forget, le receive est côté
      caller).

  Default `NotWiredYet` no-op (caller voit timeout systématique →
  `{:deny, "relay timeout"}` côté router) tant que ch11 pas câblé.
  """

  @callback relay_request(ref :: String.t(), payload :: map()) :: :ok | {:error, term()}
end

defmodule Fleet.PermissionRouter.RelayBackend.NotWiredYet do
  @moduledoc """
  Backend placeholder. Le wiring `Phoenix.PubSub.broadcast(Fleet.PubSub,
  "fleet.events", {:permission_relay_request, payload})` se fait post
  chantier 11 `fleet_event_router`.

  Retourne `:ok` no-op — le caller `receive` timeoutera → `{:deny,
  "relay timeout"}` cohérent canon §0 #1 refus par défaut.
  """

  @behaviour Fleet.PermissionRouter.RelayBackend

  @impl Fleet.PermissionRouter.RelayBackend
  def relay_request(_ref, _payload), do: :ok
end
