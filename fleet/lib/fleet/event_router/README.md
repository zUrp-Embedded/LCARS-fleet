# Fleet.EventRouter — domain card

**Date**: 2026-07-13
**Last revised**: 2026-07-18
**Status**: active — PubSub event bus `fleet.events` + events.yaml registry (substrate)
**Referenced by**: —

Event bus (Phoenix.PubSub topic `fleet.events`) + the `events.yaml` registry
(substrate: foundation-only deps, most domains depend on it). Consumption =
direct PubSub subscribers, no dispatch table. Also owns the two cross-cutting
listener primitives (bind IP, Cowboy child-spec) every HTTP surface builds on.

**This file is a map, not the contract.** Each module owns its contract in its
own `@moduledoc` — read those (`h Fleet.EventRouter.Bus` in IEx, or `lib/`).
Nothing here is restated, only pointed at.

## Modules
- `Fleet.EventRouter` — moduledoc-only facade indexing the sub-modules (no code)
- `Fleet.EventRouter.Bus` — the `Fleet.PubSub` instance; struct-only broadcast/subscribe, fail-loud registry membership
- `Fleet.EventRouter.Catalog` — boot-time loader of the `priv/event_router/events.yaml` registry (populates `authorized_event_types`)
- `Fleet.EventRouter.Application` — domain supervisor (boot runs `Catalog.load!` + atom pre-registration; PubSub under its own escalate-to-node supervisor)
- `Fleet.EventRouter.WebhooksGitea` — Gitea webhook HTTP endpoint (Plug.Router + HMAC SHA256)
- `Fleet.EventRouter.BindAddress` — single source of the listener bind IP (loopback default, exposure = named opt-in)
- `Fleet.EventRouter.Listener` — single source of the Cowboy HTTP child-spec (the "spec" counterpart of `BindAddress`)
- `Fleet.EventRouter.SignalsOS` — OS-signal → bus bridge, **INERT / gated off** (see its moduledoc)

Related, NOT this domain: `Fleet.Event` (the canonical wire struct — its own foundation
boundary, `lib/fleet/event.ex`); `Fleet.Shutdown.Quiesce` and `Fleet.SchemaCache` (own
zero-dep foundation boundaries, reachable from any domain because they depend on nothing).

## Config & deps
- Knob `:start_webhooks` — read by `Application`, runtime on-switch `LCARS_FLEET_WEBHOOKS`.
- Knob `:load_event_registry` — read by `Catalog` (default `true`; `false` in `:test`).
- Knob `:permit_when_registry_empty` — read by `Bus` (regime when the registry is empty).
- Knob `:start_signals` — read by `Application` (gated off, no on-switch).
- Knobs `:webhook_port`, `:webhook_secret_path`, `:events_yaml_path` — read by `WebhooksGitea` / `Catalog`, set by `runtime.exs`.
- Env `LCARS_BIND_HOST` / `LCARS_WEBHOOK_BIND_HOST` — read by `BindAddress`.
- Deps: the facade's `use Boundary` declaration (`lib/fleet/event_router.ex`).
