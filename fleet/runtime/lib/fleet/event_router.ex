defmodule Fleet.EventRouter do
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      # — external wire surface (lib fencing: every reference declared, cf. CLAUDE.md) —
      Phoenix.PubSub,
      Plug,
      Plug.Builder,
      Plug.Conn,
      Plug.Conn.Unfetched,
      Plug.Conn.WrapperError,
      Plug.Parsers,
      Plug.Router,
      Plug.Router.Utils
    ],
    exports: [Bus, Listener]

  @moduledoc """
  LCARS event bus + event registry (substrate: PubSub `fleet.events` — most domains
  depend on it; consumption = direct PubSub subscribers, no dispatch table).

    * `Fleet.EventRouter.Bus` — the Phoenix.PubSub instance + broadcast/subscribe (exported)
    * `Fleet.EventRouter.Listener` — HTTP listener hosting the webhook router (exported)
    * `Fleet.EventRouter.WebhooksGitea` — Plug.Router, Gitea webhooks, HMAC SHA256
    * `Fleet.EventRouter.Catalog` — loads the events.yaml registry at boot (`authorized_event_types`)
    * `Fleet.EventRouter.BindAddress` — listener bind-address resolution
    * `Fleet.EventRouter.SignalsOS` — OS-signal → bus bridge, **INERT / gated off** (see its moduledoc)
    * `Fleet.EventRouter.Application` — domain supervisor
  """
end
