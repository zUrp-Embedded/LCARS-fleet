# Fleet.Spawner

**Date** : 2026-07-11
**Dernière révision** : 2026-07-18
**Statut** : actif — carte du domaine spawner (contrats dans les `@moduledoc`)
**Référencé par** : `mix.exs`, `_remediation/` (F-C040)

Pod lifecycle (pod composition layer): spawns, watches and terminates ephemeral
agent pods. Each pod is a `gen_statem` (`Fleet.Spawner.Pod`) whose STATES are
the phases of the canonical cycle; the lifecycle IS the responsibility.

**This file is a map, not the contract.** Each module owns its contract in its
own `@moduledoc` — read those (`h Fleet.Spawner.Pod` in IEx, or `lib/`). The
state machine, the API signatures, the launch chain, recovery and the reaper
mechanics are NOT restated here, only pointed at.

## Modules

Core lifecycle:
- `Fleet.Spawner` — public-API facade (`spawn_pod`/`kill_pod`/`pod_info`/`list_pods`/`count_pods`/`wake_pod`/`recall`/`reprovision_pipe_workspace` + the `valid_pod_id?`/`brief_required?`/`restart_strategy_for` authorities); the app entry point
- `Fleet.Spawner.Pod` — the lifecycle `gen_statem` (8 states = the 8 phases; boot-chain, `:monitoring` watchdogs, guaranteed `terminate/3` teardown)
- `Fleet.Spawner.Application` — `:rest_for_one` root supervisor (Registry → Supervisor → gated consumers); boots NO permanent pod
- `Fleet.Spawner.Supervisor` — DynamicSupervisor, `:max_pods` global cap on living pods
- `Fleet.Spawner.PodTmux` — host→pod control-plane over the per-pod tmux socket (kick / `/clear` / has-session; orphan `kill_holder` fallback)
- `Fleet.Spawner.PodWarden` — periodic reaper of the substrate (orphan tmux socks + graveyard pod_dir GC, 2-tick grace)

Boot / respawn / seams:
- `Fleet.Spawner.PublishConsumer` — Bus consumer of `admin.spawn.request` → `spawn_pod/3`
- `Fleet.Spawner.PermanentBoot` — boot of the permanent Type-1 pods (invoked only by `Fleet.Starfleet.BootOrchestrator`)
- `Fleet.Spawner.PermanentWarden` — respawn of dead permanents (Bus `pod.failed`, capped backoff)
- `Fleet.Spawner.SeedStore` — checkpoint/restore of a pod's session jsonl for recall (`--resume`)
- `Fleet.Spawner.LaunchBackend` (behaviour) + `.LauncherPortBackend` (the real Port/bwrap backend) / `StubBackend` (tests)
- `Fleet.Spawner.SessionId` — pure hexspeak encoder of the deterministic claude `session_id`
- `Fleet.Spawner.McpSocketProvisioner` — behaviour of the runtime seam `:mcp_socket_provisioner` (→ `fleet_mcp`, above spawner)

- `Fleet.Spawner.Pod.*` — the 20 `gen_statem` lifecycle islands (each stateless: no state/Port/timer of its own — the `Pod` core orchestrates, the islands compute/decide/do the I/O). See each `@moduledoc`; grouped by concern:
  - placement & launch env: `Pod.Paths`, `Pod.LaunchSpec`, `Pod.LaunchEnv`, `Pod.McpProvision`, `Pod.SessionMint`
  - projecting the pod_dir: `Pod.Scaffold`, `Pod.Assets`, `Pod.Brief`, `Pod.Fs`, `Pod.SessionFiles`
  - monitoring & wake: `Pod.Liveness`, `Pod.Kick`, `Pod.TaskProbe`, `Pod.TurnFlag`, `Pod.Publishing`
  - lifecycle I/O: `Pod.Backend`, `Pod.Events`, `Pod.CompletedPayload`
  - recovery: `Pod.Recovery`, `Pod.StateFs`

## Config & deps
- Knobs `:fleet_spawner, :*` — each is read by its owning module (that `@moduledoc` is the authority for the knob's meaning + default). **Only a SUBSET is operator-tunable via an `LCARS_*` env var in `runtime.exs`** (F-C040: the earlier text wrongly implied ALL of them were): notably `:boot_permanent_at_start` (`LCARS_BOOT_PERMANENT_AT_START`), `:state_fs_root` (`LCARS_STATE_FS_ROOT`), `:tmux_sock_base` (`LCARS_TMUX_SOCK_BASE`), `:mcp_server_spec` (via `LCARS_FLEET_MCP_BRIDGE_PATH`), `:bwrap_launch_path` (`LCARS_BWRAP_LAUNCH_PATH`), `:cap_profiles_dir` (`LCARS_CAPPROFILES_ROOT`), `:seed_store_root` (`LCARS_SEED_STORE_ROOT`). The rest — consumer/boot gates (`:start_pod_warden`, `:start_publish_consumer`, `:start_permanent_warden`), `:pod_dir_root`/`:claude_dir`, backend/seams (`:launch_backend`, `:mcp_socket_provisioner`, `:event_bus`), cadences/bounds (`:max_pods`, `:pod_warden_interval_ms`, `:liveness_tick_ms`, `:kick_*`, `:publish_deadline_ms`) — are **app-env defaults set in `config/*.exs` or module defaults, NOT env-driven** (`:pod_dir_root` explicitly dropped its `LCARS_PODS_ROOT` knob, 2026-06-09). The `etc/fleet_v2.env.template` catalogue lists the env-driven vars only, not these.
- Auth is NOT a knob — `LCARS_AUTH_MODE=bind` is hard-set by `Pod.LaunchEnv` (see its `@moduledoc`).
- N0 launchers (`bin/{bwrap,host,claude}_launch.sh`) are the containment/vendor boundary, selected by `metadata.containment` — not app code (see `Pod.Backend` + the script headers).
- Deps: see `mix.exs`.
