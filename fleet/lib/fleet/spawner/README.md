# Fleet.Spawner

**Date**: 2026-07-11
**Last revised**: 2026-09-04
**Status**: active — spawner domain card (contracts live in the `@moduledoc`s)
**Referenced by**: `mix.exs`

Pod lifecycle (pod composition layer): spawns, watches and terminates ephemeral
agent pods. Each pod is a `gen_statem` (`Fleet.Spawner.Pod`) whose STATES are
the phases of the canonical cycle; the lifecycle IS the responsibility.

**This file is a map, not the contract.** Each module owns its contract in its
own `@moduledoc` — read those (`h Fleet.Spawner.Pod` in IEx, or `lib/`). The
state machine, the API signatures, the launch chain, recovery and the reaper
mechanics are NOT restated here, only pointed at.

## Modules

Core lifecycle:
- `Fleet.Spawner` — public-API facade (`spawn_pod`/`kill_pod`/`pod_info`/`list_pods`/`count_pods`/`wake_pod`/`recall`/`reprovision_pipe_workspace` + the `valid_pod_id?`/`brief_required?`/`restart_strategy_for` authorities); the domain entry point
- `Fleet.Spawner.Pod` — the lifecycle `gen_statem` (7 states = the 7 phases; `:publishing` is a FLAG, not a state; boot-chain, `:monitoring` watchdogs, guaranteed `terminate/3` teardown)
- `Fleet.Spawner.Application` — `:rest_for_one` root supervisor (Registry → Supervisor → gated consumers); boots NO permanent pod
- `Fleet.Spawner.Supervisor` — DynamicSupervisor ; `:max_pods` y est le FUSIBLE anti-emballement (pas une politique : le fan est borne par `max_fan` et les sieges de pool)
- `Fleet.Spawner.PodTmux` — host→pod control-plane over the per-pod tmux socket (kick / `/clear` / has-session; orphan `kill_holder` fallback)
- `Fleet.Spawner.BootEpoch` — identity of the CURRENT BEAM boot (per-fleet-life nonce): the discriminator that separates a POD-level recovery from a FLEET-level restart.
- `Fleet.Spawner.PodWarden` — periodic reaper of the substrate (orphan tmux socks + graveyard pod_dir GC, 2-tick grace)
- `Fleet.Spawner.PoolSlot` — allocates the `pool` nibble of a pod's `session_id`, and CAPS the concurrency of a role
- `Fleet.Spawner.CanonProof` — boot-time proof that every canon role and each optional modop is spawn-ready

Boot / respawn / seams:
- `Fleet.Spawner.PublishConsumer` — Bus consumer of `admin.spawn.request` → `spawn_pod/3`
- `Fleet.Spawner.PermanentBoot` — boot of the permanent Type-1 pods (invoked only by `Fleet.Admiral.BootOrchestrator`)
- `Fleet.Spawner.PermanentWarden` — respawn of dead permanents (Bus `pod.failed`, capped backoff)
- `Fleet.Spawner.SeedStore` — checkpoint/restore of a pod's session jsonl for recall (`--resume`)
- `Fleet.Spawner.LaunchBackend` (behaviour) + `.LauncherPortBackend` (the real Port/bwrap backend) / `StubBackend` (tests)
- `Fleet.Spawner.SessionId` — pure hexspeak encoder of the deterministic claude `session_id`
- `Fleet.Spawner.McpSocketProvisioner` — behaviour of the runtime seam `:mcp_socket_provisioner` (→ `fleet_mcp`, above spawner)

- `Fleet.Spawner.Pod.*` — the 21 `gen_statem` lifecycle islands (each stateless: no state/Port/timer of its own — the `Pod` core orchestrates, the islands compute/decide/do the I/O). See each `@moduledoc`; grouped by concern:
  - placement & launch env: `Pod.Paths`, `Pod.LaunchSpec`, `Pod.LaunchEnv`, `Pod.McpProvision`, `Pod.SessionMint`, `Pod.Egress` (the pod's ONLY way out to the network: a per-pod CONNECT proxy on an AF_UNIX socket; `Pod.Egress.Vendor` = which hosts a vendor needs, declared beside its launcher)
  - projecting the pod_dir: `Pod.Scaffold`, `Pod.Assets`, `Pod.Brief`, `Pod.Fs`, `Pod.SessionFiles`
  - monitoring & wake: `Pod.Liveness`, `Pod.Kick`, `Pod.TaskProbe`, `Pod.TurnFlag`, `Pod.Publishing`
  - lifecycle I/O: `Pod.Backend`, `Pod.Events`, `Pod.CompletedPayload`
  - recovery: `Pod.Recovery`, `Pod.StateFs`

## Config & deps
- Knobs `:lcars_fleet, :spawner_*` — each is read by its OWNING module, and that `@moduledoc` is the authority for the knob's meaning and its default.
  **This card does not list them**: an inventory in a card expires by construction — a map is the one artifact neither the gate nor a review filters, so a renamed key goes stale here without anything turning red. The rule below does not expire.
  **Only a SUBSET is operator-tunable**, through an `LCARS_*` variable read in `config/runtime.exs` — which is the source of truth for env vars — and `etc/fleet_v2.env.template` is the catalogue of exactly those. Everything else is an app-env default from `config/*.exs` or a module default, with no variable and by decision (`:spawner_pod_dir_root` deliberately has none). To know whether a given knob is tunable, read `runtime.exs`; to know what it means, read its owner.
- Auth is NOT a knob — `LCARS_AUTH_MODE=bind` is hard-set by `Pod.LaunchEnv` (see its `@moduledoc`).
- N0 launchers (`bin/{bwrap,host,claude}_launch.sh`) are the containment/vendor boundary, selected by `metadata.containment` — not app code (see `Pod.Backend` + the script headers).
- Deps: the facade's `use Boundary` declaration (`lib/fleet/spawner.ex`).
