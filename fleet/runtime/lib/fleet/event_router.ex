defmodule Fleet.EventRouter do
  # Z4 migration (2026-07-12) — frontière COMPILÉE du domaine : deps = graphe ex-umbrella
  # régularisé (successeur mécanique du verrou topologie, D-19), exports = la SURFACE
  # cross-domaine MESURÉE (Z4c : tout à [] puis violations constatées → liste). Le
  # compilateur refuse toute violation — plus de discipline. Rétrécir = geste Z6+.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      # — surface wire externe (fencing Z4b : chaque référence est déclarée) —
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
  LCARS v2 event bus + event registry (substrate: PubSub `fleet.events`, 0 deps,
  ~12 apps depend on it; consumption = direct PubSub subscribers, no dispatch table).
  See the sub-modules:

    * `Fleet.EventRouter.Bus` — Phoenix.PubSub instance + broadcast/subscribe
    * `Fleet.EventRouter.WebhooksGitea` — Plug.Router HTTP HMAC SHA256
    * `Fleet.EventRouter.SignalsOS` — OS-signal → bus bridge, **INERT / gated off** (see its moduledoc)
    * `Fleet.EventRouter.Catalog` — loads the events.yaml registry at boot (populates `authorized_event_types`)
  """
end
