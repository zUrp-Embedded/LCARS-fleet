defmodule Fleet.EventRouter do
  @moduledoc """
  LCARS v2 event bus + event registry (Ring 0 — substrate: PubSub `fleet.events`, 0 deps,
  ~12 apps depend on it; consumption = direct PubSub subscribers, no dispatch table).
  See the sub-modules:

    * `Fleet.EventRouter.Bus` — Phoenix.PubSub instance + broadcast/subscribe
    * `Fleet.EventRouter.WebhooksGitea` — Plug.Router HTTP HMAC SHA256
    * `Fleet.EventRouter.SignalsOS` — `:os.set_signal/2` GenServer
    * `Fleet.EventRouter.Catalog` — loads the events.yaml registry at boot (populates `authorized_event_types`)
  """
end
