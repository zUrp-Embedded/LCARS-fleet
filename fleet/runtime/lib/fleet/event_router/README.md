# fleet_event_router

**Date** : 2026-07-13
**Dernière révision** : 2026-07-12 (en-tête déclaratif LCARS ajouté — uniformisation acte3 vague A ; carte co-localisée `lib/fleet/<dom>/` depuis le collapse)
**Statut** : actif — bus d'événements PubSub `fleet.events` + registry events.yaml (Ring 0)
**Référencé par** : `04_design-notes/fleet_event_router.md`

Event bus (Phoenix.PubSub topic `fleet.events`) + the `events.yaml` registry
(Ring 0 — substrate: 0 dependencies, ~12 domains depend on it). Consumption =
direct PubSub subscribers, no dispatch table. Also hosts a handful of
universal-substrate primitives (bind IP, listener spec, shutdown flag, schema
cache) that must be reachable downward from any ring without a layering inversion.

**This file is a map, not the contract.** Each module owns its contract in its
own `@moduledoc` — read those (`h Fleet.EventRouter.Bus` in IEx, or `lib/`).
Nothing here is restated, only pointed at.

## Modules
- `Fleet.EventRouter` — moduledoc-only facade indexing the sub-modules (no code)
- `Fleet.Event` — the canonical `%Fleet.Event{}` wire struct (closed `source` enum, `new/3` = "parse, don't validate")
- `Fleet.EventRouter.Bus` — the `Fleet.PubSub` instance; struct-only broadcast/subscribe, fail-loud registry membership
- `Fleet.EventRouter.Catalog` — boot-time loader of the `priv/event_router/events.yaml` registry (populates `authorized_event_types`)
- `Fleet.EventRouter.Application` — app supervisor (boot runs `Catalog.load!` + atom pre-registration; PubSub under its own escalate-to-node supervisor)
- `Fleet.EventRouter.WebhooksGitea` — Gitea webhook HTTP endpoint (Plug.Router + HMAC SHA256)
- `Fleet.EventRouter.SignalsOS` — OS-signal → bus bridge, **INERT / gated off** (see its moduledoc)
- `Mix.Tasks.Lcars.Contracts.Check` — inter-module contract checker / repo coherence lock (`mix lcars.contracts.check`)

Universal-substrate primitives co-located here (Ring 0, zero new edge):
- `Fleet.EventRouter.BindAddress` — single source of the listener bind IP (loopback default, exposure = named opt-in)
- `Fleet.EventRouter.Listener` — single source of the Cowboy HTTP child-spec (the "spec" counterpart of `BindAddress`)
- `Fleet.Shutdown.Quiesce` — the shutdown-drain flag (`:persistent_term`, no process)
- `Fleet.SchemaCache` — the "load an artifact once, cache in `:persistent_term`" authority

## Config & deps
- Knob `:start_webhooks` — read by `Application`, runtime on-switch `LCARS_FLEET_WEBHOOKS`.
- Knob `:load_event_registry` — read by `Catalog` (default `true`; `false` in `:test`).
- Knob `:permit_when_registry_empty` — read by `Bus` (regime when the registry is empty).
- Knob `:start_signals` — read by `Application` (gated off, no on-switch).
- Knobs `:webhook_port`, `:webhook_secret_path`, `:events_yaml_path`, `:captured_signals` — read by `WebhooksGitea` / `Catalog` / `SignalsOS`, set by `runtime.exs`.
- Env `LCARS_BIND_HOST` / `LCARS_WEBHOOK_BIND_HOST` — read by `BindAddress`.
- Deps: see `mix.exs`.
