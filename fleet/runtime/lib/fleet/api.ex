defmodule Fleet.API do
  # COMPILED frontier of the domain: deps = the declared inter-domain graph, exports = the
  # MEASURED cross-domain surface (started at [] — only observed, reviewed violations were
  # added). The compiler refuses any violation — no discipline required. Shrinking it is a
  # deliberate API gesture.
  use Boundary,
    deps: [
      Fleet.Slug,
      Fleet.EnvParse,
      Fleet.GitRef,
      Fleet.Layout,
      Fleet.Event,
      Fleet.SchemaCache,
      Fleet.Shutdown.Quiesce,
      Fleet.CapProfile,
      Fleet.EventRouter,
      Fleet.MCP,
      Fleet.Pilot,
      Fleet.Spawner,
      Fleet.Starfleet,
      # Deliberate API widening: build_info's git read runs on the boot path — it goes
      # through the BOUNDED exec authority (Credentials.Shell), never a bare System.cmd
      # that a hung FS could hold forever.
      Fleet.Credentials,
      # — external wire surface (lib fencing: every reference is declared) —
      Plug,
      Plug.Builder,
      Plug.Conn,
      Plug.Conn.Unfetched,
      Plug.Conn.WrapperError,
      Plug.Parsers,
      Plug.Router,
      Plug.Router.Utils,
      Plug.Static,
      # api binds its OWN AF_UNIX control socket (ControlRouter), off the network the pod
      # shares; the TCP listener goes through EventRouter.Listener.
      Plug.Cowboy
    ],
    exports: [Application]

  @moduledoc """
  LCARS v2 public API (surface — external boundaries): REST + WS.

  **Client-agnostic API** — the native dashboard / observation deck is *one*
  possible consumer among others, not coupled to the v2 arch.

  ## Sub-modules

    * `Fleet.API.Rest` — Plug.Router HTTP over TCP (per-human port, laid down by bin/fleet_v2):
      no-auth GET reads (workflow_runs/issues/pods/health/version/readiness). No `X-Auth-Token`
      HMAC — the boundary is network/container isolation (`h Fleet.API.Rest` §Auth).
    * `Fleet.API.ControlRouter` — the one WRITE, `POST /api/admin/spawn`, served OFF this TCP
      surface on a local AF_UNIX socket a pod on the shared network cannot reach.
    * `Fleet.API.WS` — Cowboy WebSocket handler `:<port>/ws` subscribes the Phoenix.PubSub bus
      + per-client topic filter + 30s heartbeat

  ## Deferred split

  MVP: 1 single `fleet_api` domain (REST + WS in the same
  supervision). No duplicated bus subscribe, OTP supervision-tree
  simplicity.

  **Deferred**: split into `fleet_bus_socket` (irreducible on the
  event_router side) + `fleet_rest_facade` (optional overlay).
  Operationalizable post-implementation criterion **90 days**: if the
  first observed client consumes the raw NDJSON bus without the REST
  overlay (e.g. custom CLI, another experimental dashboard, external MCP
  server) → we split; as long as no such client exists, the split would
  be speculative.

  ## Vendor boundary

  N0 (vendor-agnostic, no inference — orchestration via the PubSub bus;
  no vendor inference in this layer).
  """
end
