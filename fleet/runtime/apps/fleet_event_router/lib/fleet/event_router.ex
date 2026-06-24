defmodule Fleet.EventRouter do
  @moduledoc """
  Bus events + registry d'events LCARS v2 (Ring 2 — colonne vertébrale orchestration ; consommation =
  subscribers PubSub directs, pas de table de dispatch). Voir les sous-modules :

    * `Fleet.EventRouter.Bus` — Phoenix.PubSub instance + broadcast/subscribe
    * `Fleet.EventRouter.WebhooksGitea` — Plug.Router HTTP HMAC SHA256
    * `Fleet.EventRouter.SignalsOS` — `:os.set_signal/2` GenServer
    * `Fleet.EventRouter.Catalog` — charge le registry events.yaml au boot (peuple `authorized_event_types`)
  """
end
