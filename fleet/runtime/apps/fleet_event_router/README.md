# Fleet.EventRouter

Event bus (Phoenix.PubSub) + LCARS v2 events.yaml registry (Ring 0 —
substrate: 0 dependencies, ~12 apps depend on it). Consumption = direct PubSub
subscribers (dispatch table removed, user decision 2026-06-05). Gitea webhooks
+ OS signals + internal events (`pod.*`, `workflow_map.*`, `work_item.*`,
`audit.verdict`, `pod.drift`)
published on Phoenix.PubSub topic `fleet.events`.

## Sub-modules

- `Fleet.EventRouter` — moduledoc-only facade (index of the sub-modules, no code)
- `Fleet.Event` — canonical event struct (**SINGLE wire format**: all
  producers emit `%Fleet.Event{}`, no tuples). `source` = closed-list enum
  (12 canonical sources), **enforced** by the `new/3` constructor
  ("parse, don't validate": an out-of-enum source raises). Also carries
  `UnregisteredError` (type outside the registry)
- `Fleet.EventRouter.Bus` — Phoenix.PubSub instance `Fleet.PubSub`
  (**struct-only** broadcast/subscribe of `%Fleet.Event{}`; the ONLY validation
  at broadcast = registry membership, fail-loud `UnregisteredError` —
  no soft JSON validation, no `Fleet.EventRouter.Schema`)
- `Fleet.EventRouter.Application` — app supervisor: `Catalog.load!` at boot,
  pre-registration of the event_type atoms (`preregister_event_atoms` — dynamic
  emitters go through `to_existing_atom`, anti atom-leak),
  `gitea_event_types/0` (single source of the emittable gitea actions), restart
  bounds 3/60; the PubSub lives under a DEDICATED supervisor `max_restarts: 0`
  (a local restart would lose all the node's subscriptions → deliberate
  escalation all the way to the node)
- `Fleet.EventRouter.WebhooksGitea` — Plug.Router HTTP (port `:webhook_port`,
  default 8081) + HMAC SHA256 verify (secret `/etc/fleet/webhook-secret`)
- `Fleet.EventRouter.SignalsOS` — `:os.set_signal/2` SIGUSR1/SIGTERM/SIGHUP
  → broadcast `os.signal.<sig>`. **Dormant (INERT)**: no runtime on-switch
  activates it (see § Configuration `:start_signals`)
- `Mix.Tasks.Lcars.Contracts.Check` — inter-module contract checker
  (repo coherence lock, see § Contracts.Check)
- `Fleet.EventRouter.Catalog` — loads the **registry** `priv/events.yaml` at boot
  (`load!/0` → `authorized_event_types`). Single parse source, exposed as:
  `event_type_strings/0` (type-keys, reused by `Application.preregister_event_atoms/0`,
  dedup) + `events_yaml_path/0` (path resolution). Consumption = direct PubSub
  subscribers (the former `Dispatch` was removed, see § Catalogue)
- `Fleet.EventRouter.BindAddress` — SINGLE source of the bind IP for the runtime's
  Cowboy listeners (`ip/1`). Lives here because it is universal substrate (like
  `Fleet.Event`) consumed by the 4 HTTP surfaces (`fleet_api`, `fleet_mcp`,
  `fleet_observation`, webhook) without layering inversion. Invariant: loopback
  `{127,0,0,1}` by default, exposure = named opt-in (`LCARS_BIND_HOST` global,
  per-surface override e.g. `LCARS_WEBHOOK_BIND_HOST`)
- `Fleet.EventRouter.Listener` — SINGLE source of the **Cowboy child-spec** for the
  HTTP listeners (`cowboy_child/1`: opts `plug`/`port` required; `scheme`,
  RAW `dispatch`, `ref`, `surface_env` optional), the "spec" counterpart of
  `BindAddress` (same "how a listener is exposed" concern — the
  loopback-by-default `:ip` is set BY CONSTRUCTION). Consumed by `fleet_api`
  (REST+WS, dispatch), `fleet_observation` (deck) and this app's Gitea
  webhook (dedup, zero new edge). The gates (`:start_listener`/
  `:start_webhooks`) and the port resolution stay with each app
- `Fleet.Shutdown.Quiesce` — shared primitive of the shutdown drain
  (`:persistent_term` flag `quiescing?/refuse!/resume!`). Lives here because it is
  universal substrate (like `Fleet.Event`): readable from any ring without
  layering inversion. Current reader: `fleet_api` (top-level gate on
  `POST /api/admin/spawn`); a former `fleet_workflow` activation reader was
  removed along with its entry point (re-wiring it belongs to the
  graceful-shutdown work that is not yet fully active). Policy (when to
  quiesce) = `fleet_starfleet` (`Shutdown.AggregateDispatcher`). No process
  (Iron Law)
- `Fleet.SchemaCache` — authority of the "artifact loaded once, cached in
  `:persistent_term`" pattern (dedup). `resolve_json_schema!(key, path)`:
  read+decode+resolve ExJsonSchema, idempotent, fail-loud at boot;
  `fetch!(key, hint)`: get-or-raise with an actionable message; `cached(key, fun)`:
  generic lazy sentinel. Lives here because it is universal substrate (like
  `Fleet.Event`): consumed by `fleet_workflow` (Loader), `fleet_starfleet`
  (Gatekeeper), `fleet_coord` (Policies) without a new edge. Written ONCE at boot,
  read on every validation — never a per-tick `put` (GC storm). No process (Iron Law)

## Main API

```elixir
# Canonical broadcast (struct %Fleet.Event{}) on the main topic — fail-loud if type outside registry.
# `broadcast_main/1` centralizes the topic literal; `main_topic/0` exposes it (authority).
Fleet.EventRouter.Bus.broadcast_main(%Fleet.Event{
  source: :spawner, type: :"pod.allocate",
  timestamp: DateTime.utc_now(), payload: %{"pod_id" => "p1"}})
# Explicit variant (arbitrary topic): Fleet.EventRouter.Bus.broadcast(Fleet.EventRouter.Bus.main_topic(), event)

# Producer idiom: construct the canonical event + broadcast to main in one call — fail-loud
# (same raises as broadcast_main + those of Fleet.Event.new, not caught).
Fleet.EventRouter.Bus.emit(:spawner, :"pod.allocate", payload: %{"pod_id" => "p1"})

# PROTECTED variant for best-effort emitters (observability/escalation) — UNIFIED error
# policy (dedup of the local rescues in coord/starfleet/spawner): UnregisteredError tolerated per
# `:on_unregistered` (`:log` default | `:silent` nominal boot-order); a malformed event (construction
# bug) is ALWAYS Logger.error + :ok — never swallowed silently, never a crash of the emitter.
# `type` also accepts a binary (to_existing_atom under the rescue, anti atom-leak).
# NOT for load-bearing events (pod.completed): those must PROPAGATE the failure.
Fleet.EventRouter.Bus.safe_emit(:starfleet, :"mcp.server_crashed",
  [payload: %{"target" => "..."}],
  on_unregistered: :silent, context: "MCPMonitor: alert NOT emitted")

# Subscribe + receive (direct subscriber = canon) — default = main_topic/0
Fleet.EventRouter.Bus.subscribe()
receive do
  %Fleet.Event{type: :"pod.allocate"} = event -> ...
end
```

There is NO 3-arity shim `broadcast(event_type, payload, opts)`: the Bus is
struct-only (see the `Fleet.EventRouter.Bus` moduledoc § "Why struct-only").

## Configuration

- `:fleet_event_router, :start_webhooks` — boots the Plug.Cowboy webhooks
  (default `false` — dev/test do not touch port `:8081`). Runtime on-switch:
  env `LCARS_FLEET_WEBHOOKS=true` (`config/runtime.exs` —
  forge integration opt-in, default OFF)
- `:fleet_event_router, :load_event_registry` — loads the events.yaml registry
  at boot (`Catalog.load!`, default `true`; `false` in `:test` for hermeticity
  — empty registry → broadcast validation off). In prod (`true`), an absent/invalid
  events.yaml **raises** (crash-boot: no Bus without
  validation — a broken deploy does not start)
- `:fleet_event_router, :permit_when_registry_empty` — Bus regime when
  `authorized_event_types` is **empty** (early boot / test without registry).
  `true` (default) = let through (an intended init safety-net, not a by-pass: as
  soon as the set is populated, validation decides); `false` = **fail-closed** (raise
  until `Catalog.load!` has loaded the registry). The empty behavior is
  thus EXPLICIT, no longer a silent hole. See `Bus.assert_authorized!/1`
- `:fleet_event_router, :start_signals` — boots the SignalsOS GenServer
  (default `false`). **No runtime on-switch sets it to `true`**
  (`config/runtime.exs`): the GenServer's `handle_info({:signal, _})` is dead
  (OS signals go to the `:erl_signal_server` gen_event, not to the GenServer;
  SIGUSR1 would even halt the VM). Module gated off pending the real fix
  (a gen_event handler); the registry's `os.signal.*` keys are dormant
- `:fleet_event_router, :webhook_port` — webhook HTTP port (default 8081;
  env override `LCARS_FLEET_WEBHOOK_PORT`, read only if
  `LCARS_FLEET_WEBHOOKS=true`)
- `LCARS_WEBHOOK_BIND_HOST` / `LCARS_BIND_HOST` (env) — bind IP of the webhook
  listener. **Loopback `127.0.0.1` by default.** The webhook is the ONLY surface
  whose public exposure is a legitimate need: a Gitea forge on another
  machine POSTs to it (loopback would block it). `LCARS_WEBHOOK_BIND_HOST`
  (e.g. `0.0.0.0`) exposes THIS listener alone, without touching the command
  surfaces (`fleet_api`, deck). `LCARS_BIND_HOST` (global) exposes it too; the
  per-surface override wins. Protection = HMAC SHA256 (independent of the bind).
  Single source: `Fleet.EventRouter.BindAddress`.
- `:fleet_event_router, :webhook_secret_path` — HMAC secret path
  (default `/etc/fleet/webhook-secret`; env override
  `FLEET_WEBHOOK_SECRET_PATH`)
- `:fleet_event_router, :events_yaml_path` — YAML registry path
  (default `priv/events.yaml` resolved via `:code.priv_dir` — holds in a release)
- `:fleet_event_router, :captured_signals` — signal atoms to capture
  (default `[:sigusr1, :sigterm, :sighup]`)

## events.yaml catalogue — registry

`priv/events.yaml` is a **pure registry**: its **keys** = `authorized_event_types`,
loaded at boot by `Fleet.EventRouter.Catalog.load!/0` → `Bus.broadcast/2`
**fails loud** on any type outside the registry (anti-recurrence lock). Every
emitted event MUST have its key. The **values are `[]`** (the runtime consumes none
of them).

**Consumption** happens through **direct subscribers** (Phoenix.PubSub:
`Bus.subscribe` + `handle_info` — WS dashboard, `AuditConsumer`, `DriftMonitor`,
`Spawner.PublishConsumer`, …). Who consumes what is documented
in each consumer's moduledoc.

> **Decision (user, 2026-06-05)**: "direct subscribers = canon". The
> `Dispatch` GenServer (an `event → handle_event/1` table, never wired — no
> module implemented `handle_event/1`) was **removed**; PubSub `subscribe` IS
> the dispatch. The registry loading, previously coupled to the off-in-prod `Dispatch`
> (→ broadcast validation inactive in prod), is now done by `Catalog.load!`
> at boot (prod-on/test-off). Audit of the ~15 emitters: the static ones emit
> registered types, the external dynamic ones (`webhooks_gitea`/`signals_os`/`policies`/
> `Pod.best_effort_broadcast`) rescue `UnregisteredError` → safe activation. The
> `pod.completed`/`work_item.completed` lifecycle goes through `required_broadcast`
> (PROPAGATES the failure, does not swallow it).

## Contracts.Check — repo coherence lock

`Mix.Tasks.Lcars.Contracts.Check` (`lib/mix/tasks/lcars.contracts.check.ex`,
~900 LOC) validates the inter-module contracts BEFORE execution: each check guards
a class of drift already encountered (red until the fix is landed) —
an agent that re-derives breaks the build. **18 checks, all implemented**
(`@pending_checks` empty); YAML output `status + checks[] + evidence
(file:line)`, exit≠0 if at least one check `fail`s.

Three launch points:

- `mix lcars.contracts.check` (`--quiet` = exit code only) — CLI/CI;
- alias `mix gate` (root mix.exs) — strict compile + tests + shell gate + checks + strict dialyzer;
- `mix release` step (`verrou_contracts/1`, root mix.exs, calls
  `run_checks/0`) — the release REFUSES to build if a contract is red.

The **combinators** live in the same file ("Combinators" section):
3 data-driven families — A `presence_check` (marker present in the code),
B `residue_check` (zero residue in living files), C `evidence_check`
(list of conditions evaluated at the call site); 9 of the 18 checks are pure
instantiations of them. Anti-hollow-green: each match is confirmed on the line
stripped of its comment (`strip_comment/1` — a mention in a comment does not
count).

## Dependencies

- `phoenix_pubsub` 2.x — distribution-ready bus
- `plug` 1.15+ + `plug_cowboy` 2.7+ — HTTP webhooks
- `jason` — JSON encode/decode
- `ex_json_schema` — **build-time** structural gate of the `events.yaml` canon
  (`events_schema_test`); NOT a broadcast-time validation (the broadcast
  checks registry membership)
- `yaml_elixir` — parses the `events.yaml` registry (Catalog + preregister; the dispatch table was removed, decision 2026-06-05)

## Cross-design-notes coherence

- Consumed by the PROMOTED design-note chantiers and by the upcoming ones
- Vendor boundary N0 (vendor-agnostic)
- MCP in-process tool routing (`fleet_*` tools) — mitigation deferred until
  after the first concrete tool lands
