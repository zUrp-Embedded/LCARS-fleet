# CLAUDE.md

**Date** : 2026-05-26
**Dernière révision** : 2026-06-16
**Statut** : guide runtime v2 (salvage cow-boy).
**Référencé par** : —

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

LCARS Fleet runtime — Elixir/OTP umbrella implementing the LCARS v2 fleet runtime (launched per-human via `bin/fleet_v2`). It is the runtime layer of the larger LCARS project at `/home/projects/LCARS/`; design notes that drive each app live in `04_design-notes/` (one per "chantier"). Each app under `apps/fleet_*/` corresponds to a numbered chantier (e.g. `fleet_api` = chantier 15, the launch substrate `bin/fleet_v2` = chantier 16) and its `README.md` is the canonical contract.

## Build / test / release

```bash
mix deps.get
mix compile --warnings-as-errors    # required gate
mix test                            # full umbrella

mix test apps/fleet_api             # one app
mix test apps/fleet_api/test/fleet/api/rest_test.exs:42   # single test (line number)

MIX_ENV=prod mix release            # builds _build/prod/rel/fleet_umbrella (self-contained, ERTS bundled)
```

Elixir `~> 1.18`. Release tag is `fleet_umbrella` and includes all apps as `:permanent` (see `mix.exs`).

Deploy/run procedure (launch via `bin/fleet_v2`, env file, launcher install) is in `etc/README.md` — do not re-derive it.

## Architecture

### Umbrella layout

15 apps under `apps/fleet_*/`, each a normal OTP app with `lib/fleet/<name>/application.ex` as its supervisor entry. Shared `config/` lives at the umbrella root.

Apps are grouped into **rings** (substrate layering, declared in each README under "Frontière vendor"):
- **Ring 0** — OS substrate: per-human launch via `bin/fleet_v2` (chantier 16, in `etc/` + `bin/`, not an app; the `User=lcars` systemd unit was retired 2026-06-16 — model = human-launches, ADR-E)
- **Ring 1** — pod primitives + vendor frontier: `fleet_spawner`, `fleet_credentials`, `fleet_cap_profile`, `fleet_sp_builder`, `fleet_project_bootstrap`, plus `bin/bwrap_launch.sh` + `bin/host_launch.sh` (launchers N0 containment, sélectionnés par `metadata.containment` — LAUNCH-Q) + `bin/claude_launch.sh` (launcher vendor N1). (`fleet_pod_runtime` retiré 2026-06-10 — app morte post-ADR-G, PODRT-D1.) (La frontière vendor N1 = ces scripts `bin/` ; il n'y a **pas** d'app `fleet_claude_bridge` — retirée au pivot ADR-G. Noms corrigés 2026-06-02 : `fleet_cap_profile`/`fleet_sp_builder`, pas `fleet_capprofile`/`fleet_spbuilder`.)
- **Ring 2** — orchestration backbone: `fleet_event_router` (Phoenix.PubSub bus `Fleet.PubSub` on topic `fleet.events`), `fleet_task_queue` (broker de mandats — `get_task`/`submit_result`, run #5), `fleet_task_monitor`, `fleet_pilot` (dispatcher webhook→pipeline, off par défaut — **client du core**, dépend compile-time du Ring 3 `fleet_pipeline` ; pas backbone pur, cf. son README « client du core ring 1, pas core »). (`fleet_ipc_filter` retiré : jamais implémenté.)
- **Ring 3** — coordination + policy: `fleet_coord`, `fleet_pipeline`, `fleet_starfleet` (Cat-5 audit), `fleet_mcp`
- **Ring 4** — external surface: `fleet_api` (REST `:8080` + WS `/ws`, **no-auth** par design — frontière = isolation réseau/container, cf. `Fleet.API.Rest` § Auth) ; `fleet_observation` (read-only observation deck `:8091`, BL-026 — dépend vers le bas Ring 1/2/3, aucune app du core ne dépend de lui)

### Vendor frontier (N0 / N1)

Anything that talks to a specific vendor (Claude SDK, future OpenAI) is **N1** and isolated behind a shell launcher in `bin/` (`claude_launch.sh` — there is **no** `fleet_claude_bridge` app; the N1 frontier IS the `bin/` script, ADR-G). Everything else is **N0** (vendor-agnostic). New vendor → new `bin/<vendor>_launch.sh` co-located with `claude_launch.sh`, same arg shape, **never** edit `bwrap_launch.sh`. Mixing vendor flags into N0 code breaks the contract.

### Pod sandboxing

Pods (per-role agent processes) are launched via one of two N0 launchers, chosen by `metadata.containment` in `do_launch` (LAUNCH-Q): `bwrap_launch.sh` (default, `containment: bwrap` — bwrap sandbox, RO mounts + tmpfs /home + bind credentials) or `host_launch.sh` (`containment: none` — architect-interactive, starfleet — same tmux-holder mechanism **without** the sandbox: the pod runs on the host as the human, `HOME` = real home → native `~/.claude`). Both `exec`/run the vendor launcher (`claude_launch.sh`). **Never edit `bwrap_launch.sh`** (sanctuaire); a new containment need = a new co-located N0 launcher, same arg shape. bwrap needs `@mount @namespace` syscalls (`unshare`/`mount`/`setns`/`pivot_root`) — the **container** must grant them (cap-add/seccomp); the retired systemd unit used to. Pod working dirs default to **`/home/<human>/pods/pod_<id>`** (per-human, `0700`, ADR-E — the pod lives under the owning human's home, isolated by OS ownership; **not** a shared `/home/pods`/`/var/lib/lcars/pods`). Not under `/tmp` (bwrap tmpfs would orphan writes). The pod runs *as* the human by **UID inheritance**: the BEAM is launched as the human (`bin/fleet_v2`, or `sshd` in the container) → the pod Port inherits the UID — **no** `systemd-run --uid`, no drop (proven live 2026-06-15).

### Event bus

`Fleet.EventRouter.Bus` (Phoenix.PubSub) is the single broadcast/subscribe substrate. Apps publish to `fleet.events` and consume via `subscribe/1`. In `:test` env hermeticity comes from consumers being off plus `fleet_event_router, load_event_registry: false` (Bus broadcasts skip validation), not a backend swap (see "Test hermeticity" below).

## Configuration layering

Three config files, evaluated in this order:

1. `config/config.exs` — compile-time defaults (sets prod/dev event backend to `PubSub`)
2. `config/<env>.exs` — `test.exs` overrides for hermetic tests (StubBackend launcher, consumers off, `load_event_registry: false`, `start_listener: false`)
3. `config/runtime.exs` — boot config, reads env vars from the human's run env (`~/.lcars/fleet_v2.env`, posed by `bin/fleet_v2`)

**Critical invariant** in `config/runtime.exs`: the entire file is wrapped in `if config_env() != :test do ... end`. Without that guard, `mix test` reads runtime.exs (Mix evaluates it in every env), flips `start_listener: true`, and Cowboy tries to bind `:8080` → umbrella boot crash. If you add runtime config, keep it inside the guard unless you genuinely want test eval.

Env vars consumed at boot (template: `etc/fleet_v2.env.template`):
`LCARS_LOG_LEVEL`, `LCARS_CAPPROFILES_ROOT`, `LCARS_PIPELINES_ROOT`, `LCARS_COORD_POLICIES_PATH`, `LCARS_STARFLEET_AUDIT_LOG`, `LCARS_BOOT_PERMANENT_AT_START`, `LCARS_CONFIG_REPO`, `FLEET_WEBHOOK_SECRET_PATH`, `FLEET_API_PORT`.
Run #5 (ADR-G / MCP / pilot — added 2026-06-02): `LCARS_LAUNCH_BACKEND` (+ `LCARS_UNSAFE_ALLOW_HOST_TMUX`), `LCARS_FLEET_MCP_URL` / `_POD_FACING_PORT` / `_BRIDGE_PATH`, `LCARS_PILOT_DISPATCHER` / `_POLL_REPO` / `_POLL_INTERVAL_MS` / `_ROUTING_PATH`, `FORGE_BASE_URL` / `FORGE_TOKEN` / `FORGE_TOKEN_FILE`.

## Test hermeticity

`config/test.exs` enforces a hermetic baseline that other tests rely on. Do not weaken it:

- `fleet_api, start_listener: false` — tests use `Plug.Test` for REST and direct Cowboy handler callbacks for WS, never a real socket
- consumers off (`start_*: false`) + `fleet_event_router, load_event_registry: false` — no parasitic Bus broadcasts in async tests
- `fleet_spawner, launch_backend: StubBackend` — no real bwrap spawn; tests re-set in `setup` and **do not** delete in `on_exit` (other tests rely on the default)
- `fleet_starfleet, start_audit_consumer: false` + `start_boot_orchestrator: false`, `fleet_spawner, start_publish_consumer: false` — consumers off by default; tests that need them start manually with isolated opts

When a test needs the real backend, it instantiates it directly (e.g. `start_supervised` with explicit args), it does not flip the global config.

## Code conventions

- Each app's `README.md` is the **contract**: list of submodules, public API, configuration knobs, dependencies. When adding modules, update the README.
- Header comments at the top of shell scripts use the LCARS format (`SOURCE: / AUTHOR: / STARDATE: / STATUS:`). Stardate gets updated by the `/push-github` skill — don't hand-edit it before pushing.
- Bug-fix comments often carry an incident reference like `#578` / `#582` / `B4` / `D6` — these point to past regressions. Keep the reference when modifying nearby code; it's load-bearing for future debugging.
- `apps/*/tmp/` is gitignored ExUnit `@tag :tmp_dir` artefacts — never check in.
